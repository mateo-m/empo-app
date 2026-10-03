#import "AppMemory.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <sys/mman.h>

#import "AppMemoryHeap.h"
#import "EmpoGameProcessProtocol.h"
#include "fishhook.h"

#define PAGE (16u << 10)

// Raw pages: the mmap calls of the cores.

static char gFrameworks[PATH_MAX];
// The start and the size of each mapping that came from the block.
static CFMutableDictionaryRef gMappings;
static os_unfair_lock gMappingsLock = OS_UNFAIR_LOCK_INIT;
static void *(*realMmap)(void *, size_t, int, int, int, off_t);
static int (*realMunmap)(void *, size_t);

static void *blockMmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    bool anonymous = addr == NULL && fd == -1 && (flags & MAP_ANON) && (flags & MAP_PRIVATE) && !(flags & MAP_FIXED) &&
                     prot == (PROT_READ | PROT_WRITE);
    if (!anonymous) return realMmap(addr, len, prot, flags, fd, offset);
    size_t size = (len + PAGE - 1) / PAGE * PAGE;
    void *pages = EmpoHeapPages(size);
    if (pages == NULL) return MAP_FAILED;
    os_unfair_lock_lock(&gMappingsLock);
    CFDictionarySetValue(gMappings, pages, (const void *)size);
    os_unfair_lock_unlock(&gMappingsLock);
    return pages;
}

// The heap frees only whole blocks, so a munmap of a part of a mapping
// keeps the whole mapping until the process ends.
static int blockMunmap(void *addr, size_t len) {
    os_unfair_lock_lock(&gMappingsLock);
    size_t size = (size_t)CFDictionaryGetValue(gMappings, addr);
    bool whole = size != 0 && len >= size;
    if (whole) CFDictionaryRemoveValue(gMappings, addr);
    os_unfair_lock_unlock(&gMappingsLock);
    if (size == 0) return realMunmap(addr, len);
    if (whole) {
        // The caller can have made a guard page with mprotect.
        mprotect(addr, size, PROT_READ | PROT_WRITE);
        EmpoHeapFree(addr);
    }
    return 0;
}

static void imageAdded(const struct mach_header *header, intptr_t slide) {
    Dl_info info;
    if (!dladdr(header, &info) || info.dli_fname == NULL || strncmp(info.dli_fname, gFrameworks, strlen(gFrameworks)) != 0) {
        return;
    }
    struct rebinding hooks[] = {
        {"mmap", blockMmap, (void **)&realMmap},
        {"munmap", blockMunmap, (void **)&realMunmap},
    };
    rebind_symbols_image((void *)header, slide, hooks, 2);
}

// Images: plain 2D pictures go in the block, as linear textures on a
// buffer of its memory.

typedef id (*NewTexture)(id, SEL, MTLTextureDescriptor *) NS_RETURNS_RETAINED;
static NewTexture realNewTexture;

static id blockTexture(id device, SEL selector, MTLTextureDescriptor *descriptor) NS_RETURNS_RETAINED {
    MTLPixelFormat format = descriptor.pixelFormat;
    bool plain = descriptor.textureType == MTLTextureType2D && descriptor.sampleCount == 1 && descriptor.arrayLength == 1 &&
                 (format == MTLPixelFormatRGBA8Unorm || format == MTLPixelFormatBGRA8Unorm);
    if (!plain) return realNewTexture(device, selector, descriptor);
    NSUInteger alignment = [device minimumLinearTextureAlignmentForPixelFormat:format];
    NSUInteger bytesPerRow = (descriptor.width * 4 + alignment - 1) / alignment * alignment;
    NSUInteger size = (bytesPerRow * descriptor.height + PAGE - 1) / PAGE * PAGE;
    void *bytes = EmpoHeapPages(size);
    if (bytes == NULL) return realNewTexture(device, selector, descriptor);
    id<MTLBuffer> buffer = [device newBufferWithBytesNoCopy:bytes
                                                     length:size
                                                    options:MTLResourceStorageModeShared
                                                deallocator:^(void *pointer, NSUInteger length) {
                                                  EmpoHeapFree(pointer);
                                                }];
    if (buffer == nil) {
        EmpoHeapFree(bytes);
        return realNewTexture(device, selector, descriptor);
    }
    MTLTextureDescriptor *linear = [descriptor copy];
    linear.storageMode = MTLStorageModeShared;
    // A linear texture has 1 level. ANGLE asks for the full mip chain of
    // every texture, but reads the level count back from the texture and
    // skips the levels it does not have.
    linear.mipmapLevelCount = 1;
    linear.resourceOptions = MTLResourceStorageModeShared;
    id texture = [buffer newTextureWithDescriptor:linear offset:0 bytesPerRow:bytesPerRow];
    return texture ?: realNewTexture(device, selector, descriptor);
}

void EmpoUseAppMemory(xpc_object_t memory) {
    mach_port_t entry = xpc_dictionary_copy_mach_send(memory, EmpoGameProcessMemoryEntry);
    uint64_t size = xpc_dictionary_get_uint64(memory, EmpoGameProcessMemorySize);
    if (entry == MACH_PORT_NULL || size == 0) return;
    vm_address_t start = 0;
    kern_return_t mapped = vm_map(mach_task_self(), &start, size, 0, VM_FLAGS_ANYWHERE, entry, 0, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
    mach_port_deallocate(mach_task_self(), entry);
    if (mapped != KERN_SUCCESS) {
        NSLog(@"[game-process] cannot map the app's memory: %s", mach_error_string(mapped));
        return;
    }
    if (!EmpoUseHeap((void *)start, size)) {
        NSLog(@"[game-process] mimalloc refused the app's memory");
        return;
    }

    // The extension sits in Empo.app/Extensions, and the cores in
    // Empo.app/Frameworks.
    NSURL *frameworks = [NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:@"Frameworks/"];
    realpath(frameworks.fileSystemRepresentation, gFrameworks);
    strlcat(gFrameworks, "/", sizeof gFrameworks);
    gMappings = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    realMmap = mmap;
    realMunmap = munmap;
    _dyld_register_func_for_add_image(imageAdded);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    Method method = class_getInstanceMethod(object_getClass(device), @selector(newTextureWithDescriptor:));
    if (method != NULL) realNewTexture = (NewTexture)method_setImplementation(method, (IMP)blockTexture);
}

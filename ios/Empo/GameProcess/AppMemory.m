#import "AppMemory.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
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
static void *(*realMmap)(void *, size_t, int, int, int, off_t);
static int (*realMunmap)(void *, size_t);

// The pages come from chunks of the block, with one bit for each page in
// use, so that a munmap can give back any part of a mapping.
// Ruby 3.1 and later map twice the size of a heap page, then unmap the
// head and the tail. A mapping takes the highest free pages of a chunk,
// so the next mapping starts in the head that the last one gave back.
#define CHUNK_PAGES 512u
typedef struct {
    char *start;
    size_t pages, free;
    uint64_t used[];
} Chunk;
static Chunk **gChunks;
static size_t gChunkCount;
static os_unfair_lock gChunksLock = OS_UNFAIR_LOCK_INIT;

static bool pageUsed(const Chunk *chunk, size_t page) { return chunk->used[page / 64] >> (page % 64) & 1; }

// Returns the first page of the highest run of `count` free pages, or -1.
static long freeRun(const Chunk *chunk, size_t count) {
    size_t run = 0;
    for (size_t page = chunk->pages; page-- > 0;) {
        if (page % 64 == 63 && chunk->used[page / 64] == UINT64_MAX) {
            run = 0;
            page -= 63;
        } else if (pageUsed(chunk, page)) {
            run = 0;
        } else if (++run == count) {
            return (long)page;
        }
    }
    return -1;
}

static Chunk *newChunk(size_t count) {
    size_t pages = count > CHUNK_PAGES ? (count + 63) / 64 * 64 : CHUNK_PAGES;
    Chunk *chunk = calloc(1, sizeof(Chunk) + pages / 8);
    Chunk **chunks = chunk == NULL ? NULL : realloc(gChunks, (gChunkCount + 1) * sizeof *gChunks);
    if (chunks != NULL) gChunks = chunks;
    if (chunks == NULL || (chunk->start = EmpoHeapPages(pages * PAGE)) == NULL) {
        free(chunk);
        return NULL;
    }
    chunk->pages = chunk->free = pages;
    gChunks[gChunkCount++] = chunk;
    return chunk;
}

static void *blockMmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    bool anonymous = addr == NULL && fd == -1 && (flags & MAP_ANON) && (flags & MAP_PRIVATE) && !(flags & MAP_FIXED) &&
                     prot == (PROT_READ | PROT_WRITE) && len > 0 && len <= PTRDIFF_MAX;
    if (!anonymous) return realMmap(addr, len, prot, flags, fd, offset);
    size_t count = (len + PAGE - 1) / PAGE;
    os_unfair_lock_lock(&gChunksLock);
    Chunk *chunk = NULL;
    long first = -1;
    for (size_t i = 0; i < gChunkCount && first < 0; i++) {
        chunk = gChunks[i];
        if (chunk->free >= count) first = freeRun(chunk, count);
    }
    if (first < 0 && (chunk = newChunk(count)) != NULL) first = (long)(chunk->pages - count);
    if (first < 0) {
        os_unfair_lock_unlock(&gChunksLock);
        errno = ENOMEM;
        return MAP_FAILED;
    }
    for (size_t page = (size_t)first; page < (size_t)first + count; page++) chunk->used[page / 64] |= 1ull << (page % 64);
    chunk->free -= count;
    os_unfair_lock_unlock(&gChunksLock);
    char *pages = chunk->start + (size_t)first * PAGE;
    // mmap gives zeroed pages. Zeroing the whole chunk up front would
    // put pages that no mapping uses in real memory.
    memset(pages, 0, count * PAGE);
    return pages;
}

static int blockMunmap(void *addr, size_t len) {
    os_unfair_lock_lock(&gChunksLock);
    size_t i = 0;
    while (i < gChunkCount && ((char *)addr < gChunks[i]->start ||
                               (char *)addr >= gChunks[i]->start + gChunks[i]->pages * PAGE)) {
        i++;
    }
    if (i == gChunkCount) {
        os_unfair_lock_unlock(&gChunksLock);
        return realMunmap(addr, len);
    }
    if ((uintptr_t)addr % PAGE != 0 || len == 0 || len > PTRDIFF_MAX) {
        os_unfair_lock_unlock(&gChunksLock);
        errno = EINVAL;
        return -1;
    }
    Chunk *chunk = gChunks[i];
    size_t first = (size_t)((char *)addr - chunk->start) / PAGE;
    size_t end = MIN(first + (len + PAGE - 1) / PAGE, chunk->pages);
    // The caller can have made a guard page with mprotect.
    mprotect(chunk->start + first * PAGE, (end - first) * PAGE, PROT_READ | PROT_WRITE);
    for (size_t page = first; page < end; page++) {
        if (!pageUsed(chunk, page)) continue;
        chunk->used[page / 64] &= ~(1ull << (page % 64));
        chunk->free++;
    }
    if (chunk->free == chunk->pages) {
        gChunks[i] = gChunks[--gChunkCount];
        EmpoHeapFree(chunk->start);
        free(chunk);
    }
    os_unfair_lock_unlock(&gChunksLock);
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
    memset(bytes, 0, size);
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
    realMmap = mmap;
    realMunmap = munmap;
    _dyld_register_func_for_add_image(imageAdded);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    Method method = class_getInstanceMethod(object_getClass(device), @selector(newTextureWithDescriptor:));
    if (method != NULL) realNewTexture = (NewTexture)method_setImplementation(method, (IMP)blockTexture);
}

// Upstream ANGLE's Metal backend expects a CALayer* as the EGL native window,
// not a UIWindow*. This ObjC++ helper extracts the layer from SDL's UIWindow.

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#include <SDL_syswm.h>

extern "C" void *mkxp_getANGLENativeLayer(void *sdlWindow) {
    SDL_SysWMinfo wmInfo;
    SDL_VERSION(&wmInfo.version);
    if (!SDL_GetWindowWMInfo((SDL_Window *)sdlWindow, &wmInfo))
        return nullptr;
    UIWindow *uiWindow = wmInfo.info.uikit.window;
    CALayer *layer = uiWindow.rootViewController.view.layer;

    // ANGLE bypasses SDL's EAGL view, which normally sets
    // contentScaleFactor = nativeScale for Retina rendering.
    // Without this, the Metal drawable is created at 1x resolution.
    layer.contentsScale = uiWindow.screen.nativeScale;

    return (__bridge void *)layer;
}

// ANGLE's GL_MAX_TEXTURE_SIZE can exceed the actual Metal device limit
// (e.g. ANGLE reports 16384 on simulator where Metal only supports 8192).
// Query the real limit by checking Metal GPU family support.
extern "C" int mkxp_getMetalMaxTextureSize(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return 4096;

#if TARGET_OS_SIMULATOR
    // Simulator Metal devices have stricter limits than the host GPU.
    // The GPU family checks report the host Mac's capabilities, not
    // the simulated device's. Hardcode the known simulator limit.
    return 8192;
#else
    // Real devices: use GPU family to determine the documented limit.
    // Apple3+ (A9 and later): 16384
    // Apple2 (A8): 8192
    // Apple1 (A7): 4096
    if ([device supportsFamily:MTLGPUFamilyApple3])
        return 16384;
    if ([device supportsFamily:MTLGPUFamilyApple2])
        return 8192;
    return 4096;
#endif
}

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

// Sync the CAMetalLayer (and its parent CALayer's contentsScale) to
// the current UIKit bounds on rotation. eglQuerySurface returns
// ANGLE's cached `mCurrentKnownDrawableSize` which only refreshes
// inside obtainNextDrawable - i.e., when the RGSS thread actually
// renders a frame. During a rotation event, the engine needs the
// new drawable dims immediately to post them to the RGSS thread,
// so we push them ourselves here.
//
// Must run on the main thread (CA layer mutations). Callable from
// any thread: dispatches synchronously to main if needed.
//
// Returns the post-refresh pixel dimensions in *outW / *outH. Both
// pointers are optional.
extern "C" void mkxp_refreshANGLENativeLayerSize(void *sdlWindow,
                                                 int *outW, int *outH) {
    __block CGFloat pixelW = 0;
    __block CGFloat pixelH = 0;

    dispatch_block_t work = ^{
        SDL_SysWMinfo wmInfo;
        SDL_VERSION(&wmInfo.version);
        if (!SDL_GetWindowWMInfo((SDL_Window *)sdlWindow, &wmInfo))
            return;
        UIWindow *uiWindow = wmInfo.info.uikit.window;
        CALayer *parentLayer = uiWindow.rootViewController.view.layer;
        CGFloat scale = uiWindow.screen.nativeScale;

        // contentsScale may have drifted if the window was moved to
        // another screen (iPad multitasking). Re-apply each time.
        parentLayer.contentsScale = scale;

        CGRect bounds = parentLayer.bounds;
        pixelW = bounds.size.width * scale;
        pixelH = bounds.size.height * scale;

        // Find ANGLE's CAMetalLayer sublayer and push the new
        // drawableSize + bounds. ANGLE inserted it as a sublayer
        // inside initialize() since the parent is a plain CALayer.
        for (CALayer *sub in parentLayer.sublayers) {
            if ([sub isKindOfClass:[CAMetalLayer class]]) {
                CAMetalLayer *metal = (CAMetalLayer *)sub;
                metal.bounds = bounds;
                metal.contentsScale = scale;
                metal.drawableSize = CGSizeMake(pixelW, pixelH);
                break;
            }
        }
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }

    if (outW) *outW = (int)pixelW;
    if (outH) *outH = (int)pixelH;
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

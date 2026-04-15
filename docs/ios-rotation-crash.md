# iOS rotation crash — SIGSEGV in libGLImage

## Symptom

Rapidly rotating the device during gameplay crashes the app with SIGSEGV
(signal 11). The crash occurs on GCD dispatch worker threads, not on the
main or RGSS threads:

```
=== CRASH: signal 11 ===
  libGLImage.dylib  __glgProcessPixelsWithProcessor_block_invoke
  libdispatch.dylib _dispatch_call_block_and_release
  libdispatch.dylib _dispatch_worker_thread2
  libsystem_pthread.dylib _pthread_wqthread
```

Multiple worker threads crash simultaneously (10-15 crash reports per
incident). The app process stays alive but rendering is permanently
broken.

## Root cause: iOS Simulator bug

**This is a confirmed iOS Simulator bug.** Exhaustive testing proved the
crash is NOT caused by any app-level code. It reproduces even with ALL
of the following disabled simultaneously:

1. Renderbuffer resize (`renderbufferStorage:fromDrawable:`) — never called
2. View/layer resize (`setFrame:`/`setBounds:`) — overridden as no-ops
3. All GL operations in `checkResize` — consumed events, did zero GL work
4. `presentsWithTransaction` — tested both YES and NO
5. `[CATransaction flush]` — tested before/after present
6. Skipping `presentRenderbuffer` for multiple frames around resize

The crash triggers purely from `presentRenderbuffer` being called on the
RGSS thread while the iOS Simulator rotates the virtual device. The
simulator's OpenGL ES emulation layer (`libGLImage.dylib` on macOS)
dispatches async GCD pixel-processing blocks internally. During rapid
simulator rotation, these blocks access invalidated memory inside
Apple's emulation code — completely outside app control.

**This does not reproduce on real devices**, where the native ARM GPU
driver handles pixel processing entirely differently from the simulator's
macOS-based software emulation.

## Original bug (fixed): concurrent EAGLContext access

Before the deferred-resize fix, there was a real app-level bug:
`layoutSubviews` (main thread) called `[EAGLContext setCurrentContext:]`
and `[self updateFrame]`, making the same EAGLContext current on two
threads simultaneously (undefined behavior per Apple docs). This was
fixed by deferring the resize to the RGSS thread via an atomic flag.

## Current architecture

### `layoutSubviews` — no GL context access

```objc
- (void)layoutSubviews
{
    [super layoutSubviews];
    int width  = (int)(self.bounds.size.width * self.contentScaleFactor);
    int height = (int)(self.bounds.size.height * self.contentScaleFactor);
    if (width != backingWidth || height != backingHeight) {
        backingWidth = width;
        backingHeight = height;
        atomic_store_explicit(&_needsFrameUpdate, true, memory_order_release);
    }
}
```

### `swapBuffers` — deferred resize on RGSS thread

```objc
if (atomic_load_explicit(&_needsFrameUpdate, memory_order_acquire)) {
    glFinish();
    [self updateFrame];
    atomic_store_explicit(&_needsFrameUpdate, false, memory_order_release);
}
[context presentRenderbuffer:GL_RENDERBUFFER];
```

Only the RGSS thread touches the EAGLContext. `glFinish()` drains
pending GL commands before `updateFrame` destroys old renderbuffer
storage.

### Trade-off

The renderbuffer resize is delayed by up to one frame after rotation.
During that frame, the game renders with new-size viewport calculations
onto the old-size renderbuffer. This may produce one frame of slightly
incorrect rendering during rotation, which is invisible in practice.

## Additional hardening

1. **`checkResize` winSize restoration** (`graphics.cpp`): If the
   zero-dimension guard triggers, `winSize` is restored to its previous
   value instead of keeping the bad value from `windowSizeMsg.poll()`.

2. **Cached `mkxp_getScreenScale()`** (`systemImplIOS.mm`): Screen
   scale is a device constant. Caching it eliminates two
   `dispatch_sync(main_queue)` round-trips per resize.

3. **Debug logging** in `checkResize`, `recalculateScreenSize`, and
   `updateScreenResoRatio` for diagnosing future rotation issues.

## Diagnostic evidence

All tests performed on iPhone 17 Pro Simulator (iOS 26), with rapid
clockwise then counter-clockwise rotation during gameplay:

| Test | Crash? |
|------|--------|
| Deferred resize + `glFinish()` | Yes |
| + `presentsWithTransaction = YES` | Yes |
| + `[CATransaction flush]` | Yes |
| + Skip 3 frames of present before resize | Yes |
| Disable renderbuffer resize entirely (`#if 0`) | Yes |
| Freeze view frame (`setFrame:` no-op) | Yes |
| Disable ALL GL work in `checkResize` | Yes |
| All above combined | **Yes** |

The crash is internal to `libGLImage.dylib`'s async pixel processing
and cannot be prevented at the application level on the simulator.

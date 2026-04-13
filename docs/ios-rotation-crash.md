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

## Root cause

A three-thread race condition between the main thread (UIKit rotation),
the RGSS thread (game rendering), and GCD worker threads (async pixel
processing from the iOS OpenGL ES compositor).

### The race

```
Timeline:
─────────────────────────────────────────────────────────────

RGSS thread         Main thread              GCD workers
───────────         ───────────              ───────────
presentRenderbuffer
  → dispatches async                         processing pixels
    pixel work                               from renderbuffer A
                                             (still reading...)

                    UIKit rotation
                    → layoutSubviews
                    → setCurrentContext(ctx)  ← UB: same context
                    → updateFrame              on two threads!
                    → renderbufferStorage:
                      fromDrawable:
                      ╰─ DESTROYS storage A  still reading A → SIGSEGV
```

### Why it happens

1. **`[context presentRenderbuffer:]`** (called from `SDL_GL_SwapWindow`
   on the RGSS thread) submits renderbuffer contents to the iOS
   compositor. Apple's implementation dispatches async pixel processing
   to GCD worker threads via `libGLImage`.

2. **`layoutSubviews`** (called by UIKit on the main thread during
   rotation) calls `[EAGLContext setCurrentContext:context]` — making
   the **same** EAGLContext current on both the main and RGSS threads
   simultaneously. This is **undefined behavior** per Apple's
   documentation: _"Do not access the same EAGLContext object from
   multiple threads simultaneously."_

3. **`updateFrame`** calls `[context renderbufferStorage:GL_RENDERBUFFER
   fromDrawable:]` which **destroys the old renderbuffer storage** and
   allocates new storage for the rotated dimensions.

4. The GCD worker threads are still reading from the old (now freed)
   renderbuffer storage → **SIGSEGV**.

### Why glFinish() alone didn't fix it

Two failed attempts before the final fix:

- **`glFinish()` after `SDL_GL_SwapWindow` on the RGSS thread**: The
  renderbuffer destruction happens on the main thread via
  `layoutSubviews`, which can run between any two RGSS thread
  operations. `glFinish()` on the RGSS thread can't prevent the main
  thread from destroying the buffer at any moment.

- **`glFinish()` in `updateFrame` on the main thread**: The same
  EAGLContext is current on two threads (UB). `glFinish()` on the main
  thread cannot reliably drain work submitted by the RGSS thread because
  per-thread GL command queues are in an undefined state.

## The fix

**Defer the renderbuffer resize from the main thread to the RGSS
thread.** The RGSS thread is the sole owner of the EAGLContext, so it
can safely drain its own async work and resize the renderbuffer.

### Modified files

- `ios/Dependencies/sources/sdl2/src/video/uikit/SDL_uikitopenglview.m`

### Changes

**1. `layoutSubviews` — no longer touches the GL context**

```objc
- (void)layoutSubviews
{
    [super layoutSubviews];
    int width  = (int)(self.bounds.size.width * self.contentScaleFactor);
    int height = (int)(self.bounds.size.height * self.contentScaleFactor);
    if (width != backingWidth || height != backingHeight) {
        // Update backing dimensions so SDL_GL_GetDrawableSize returns
        // correct values immediately (used by the event thread).
        backingWidth = width;
        backingHeight = height;
        // Flag the RGSS thread to perform the actual GL resize.
        atomic_store_explicit(&_needsFrameUpdate, true, memory_order_release);
    }
}
```

Previously, `layoutSubviews` called `[EAGLContext setCurrentContext:]`
and `[self updateFrame]`, performing GL operations on the main thread
while the RGSS thread was using the same context.

**2. `swapBuffers` — performs deferred resize before presenting**

```objc
if (atomic_load_explicit(&_needsFrameUpdate, memory_order_acquire)) {
    glFinish();          // drain async pixel work from previous present
    [self updateFrame];  // safely resize renderbuffer (old storage freed)
    atomic_store_explicit(&_needsFrameUpdate, false, memory_order_release);
}
[context presentRenderbuffer:GL_RENDERBUFFER];
```

This runs on the RGSS thread, which:
- Is the sole thread with the EAGLContext current (no UB)
- Calls `glFinish()` to drain its own async work (guaranteed to work)
- Then safely resizes the renderbuffer (no readers of old storage)

### Why this works

- **No concurrent context access.** Only the RGSS thread touches the
  EAGLContext. `layoutSubviews` just sets a flag and updates dimensions.
- **`glFinish()` works correctly.** Called from the thread that owns the
  context, it reliably drains all pending GPU work including the async
  pixel processing dispatched by the previous `presentRenderbuffer`.
- **No freed-storage reads.** By the time `updateFrame` destroys the old
  renderbuffer storage, all GCD workers have finished reading from it.

### Trade-off

The renderbuffer resize is delayed by up to one frame after rotation
(until the next `swapBuffers` call). During that frame, the game renders
to the old-size renderbuffer with new-size viewport calculations. This
may produce one frame of slightly incorrect rendering during rotation,
which is invisible in practice.

## Additional hardening (same commit)

These changes aren't strictly necessary for the crash fix but prevent
related issues during rotation:

1. **`checkResize` winSize restoration** (`graphics.cpp`): If the
   zero-dimension guard triggers, `winSize` is restored to its previous
   value instead of keeping the bad value from `windowSizeMsg.poll()`.

2. **Cached `mkxp_getScreenScale()`** (`systemImplIOS.mm`): Screen
   scale is a device constant. Caching it eliminates two
   `dispatch_sync(main_queue)` round-trips per resize, removing a
   potential source of RGSS thread stalls during UIKit rotation
   animations.

3. **Debug logging** in `checkResize`, `recalculateScreenSize`, and
   `updateScreenResoRatio` for diagnosing future rotation issues.

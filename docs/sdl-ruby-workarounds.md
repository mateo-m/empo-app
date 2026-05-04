# SDL & Ruby Lifecycle Workarounds

## Why This Exists

The iOS port of mkxp-z keeps SDL, the GL context, OpenAL, and the active Ruby VM alive for the process lifetime. Two fundamental constraints drove the architecture:

1. **SDL cannot be restarted** - `SDL_Init`/`SDL_Quit` and window creation are designed for a single process lifetime.
2. **Ruby cannot be restarted** - `ruby_init()` and `ruby_cleanup()` are one-shot operations; calling `ruby_cleanup()` destroys the VM and a subsequent `ruby_init()` crashes because Ruby's `Init_*` functions stash VALUEs in file-scope statics that don't get reset.

These constraints cascade into every layer of the architecture. Cross-session play (running multiple games sequentially in one process) has been parked behind a feature flag - see `multi-session.md`. The persistent-resource architecture below still applies because the active Ruby + SDL stay alive even though we no longer try to swap games.

---

## 1. Persistent SDL Window, ANGLE EGL Context, and OpenAL Device

**Problem:** SDL creates a window on `SDL_Init`. Destroying and recreating it between game sessions causes GL context issues on iOS.

**Solution (`main.cpp`):** The SDL window, ANGLE EGL context, and OpenAL device are created **once** and reused across all game sessions. iOS uses ANGLE (OpenGL ES over Metal) exclusively - the legacy EAGL/OpenGL ES path was removed because it crashed on device rotation due to a threading race in SDL's `CAEAGLLayer` renderbuffer reallocation, and Apple deprecated OpenGL ES in iOS 12.

```cpp
// Created once, persist for the process lifetime
SDL_Window *persistWin = SDL_CreateWindow(...);  // no SDL_WINDOW_OPENGL - ANGLE uses a plain CALayer
initANGLE(persistWin);  // sets up s_eglDisplay / s_eglSurface / s_eglContext
ALCdevice *persistAlcDev = alcOpenDevice(0);
ALCcontext *persistAlcCtx = alcCreateContext(persistAlcDev, 0);
```

At the end of each session, the EGL and AL contexts are **detached** from the RGSS thread (not destroyed), so the next session's thread can claim them:

```cpp
// Don't destroy - just detach from the dying thread
alcMakeContextCurrent(NULL);
eglMakeCurrent(s_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
```

### Screen FBO Capture

The screen FBO is captured once right after `initANGLE()` and reused forever. Under ANGLE/Metal it's typically 0, but we never re-query `GL_FRAMEBUFFER_BINDING` on subsequent sessions because `SharedState::finiInstance` deleted all game FBOs by then.

```cpp
static GLuint s_screenFBO = 0;
// Captured once in initANGLE:
glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
s_screenFBO = static_cast<GLuint>(fbo);
```

---

## 2. The `while(true)` Game Session Loop

**Problem:** Since SDL and Ruby can't be torn down and rebuilt, we can't simply exit `main()` and re-enter it.

**Solution (`main.cpp`):** A `while(true)` loop on the main thread manages game sessions. Each iteration spawns a new RGSS thread for the game, waits for it to finish, then loops back to wait for the next game selection.

```text
main thread:  SDL_Init → create window → while(true) { wait for game → spawn RGSS thread → wait for thread → cleanup → continue }
RGSS thread:  load game → run Ruby → exit thread
```

Between sessions:

- Stale SDL events (especially `SDL_QUIT` from the previous session) are flushed
- All input state arrays are zeroed
- The framebuffer is cleared to black to prevent flashing the last frame
- Bridge state is reset

---

## 3. Ruby VM Kept Alive Across Sessions

**Problem (`binding-mri.cpp`):** Calling `ruby_cleanup()` destroys the VM struct but leaves dangling static C pointers in extension `Init_*` functions (e.g. `Init_String` stashes class VALUEs in file-scope statics). A subsequent `ruby_init()` crashes in `rb_call_inits`. This is a known upstream Ruby limitation.

**Solution:** The active Ruby VM is initialized **once** and kept alive for the lifetime of the process. `mriBindingExecute` is split into:

- `InitOnce` - `ruby_init`, `topSelf` registration, runs once per process.
- `PerSession` - `mriBindingInit`, script execution, runs every session to reinstall C methods on top of game-script redefinitions.

Multi-Ruby (`docs/multi-ruby.md`) means there are technically four Ruby builds in the binary, but only one is active per process - whichever the first selected game's detection picked. Switching to a different Ruby version mid-process isn't supported because the chosen version's `ruby_init` already ran.

The historical `resetBetweenSessions()` cleanup (constant-baseline diffing, singleton-method scrubbing, `$mouse` shim, RGSS disposable detachment) is dormant - cross-session play is disabled. Same-session reset hooks (`$__mkxp_reset_hooks`, GC cycle, etc.) still fire if a game raises `Reset` mid-play, since the user is staying in the same game.

---

## 4. Run Loop Pumping While Waiting

**Problem (`app_bridge.cpp`):** `SDL_main` runs on the main thread on iOS. When the engine is waiting for the user to select a game from the Library UI, UIKit must still be able to render and handle events.

**Solution:** The wait loop pumps `CFRunLoop` manually:

```cpp
while (!s_pathSet.load(std::memory_order_acquire)) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
}
```

This keeps UIKit alive (rendering the SwiftUI Library) while the C++ engine blocks on the main thread.

---

## 5. Callback-Based State Notification

**Problem:** The SwiftUI Library UI and the C++ engine communicate through a C bridge (`app_bridge.h`). The UI needs to know when the engine changes state (first frame rendered, viewport rect changed, engine terminated).

**Solution (`AppState.swift`, `app_bridge.cpp`):** The bridge provides callback registration functions that the UI registers once at init. Callbacks fire on the engine thread; Swift dispatches to the main thread for UI updates.

```swift
// Registered once in AppState.init()
mkxp_setFrameRenderedCallback({ _ in
    DispatchQueue.main.async {
        // First frame: transition from .loading to .playing
        // Resume: signal snapshot can fade
    }
}, nil)

mkxp_setEngineTerminatedCallback({ _ in
    DispatchQueue.main.async { GameLibrary.shared.reload() }
}, nil)

mkxp_setGameRectChangedCallback({ x, y, w, h, _ in
    DispatchQueue.main.async { EngineState.shared.gameRect = CGRect(...) }
}, nil)
```

The engine calls these callbacks at the appropriate points. The rect callback only fires when the value actually changes.

---

## 6. Engine Termination via SDL_QUIT Injection

**Problem:** There's no direct "kill engine" function. The engine runs its own event loop.

**Solution:** Quitting is achieved by pushing `SDL_QUIT` into SDL's event queue. The engine's event loop picks it up and initiates normal shutdown:

```cpp
void mkxp_requestTerminate(void) {
    SDL_Event event;
    event.type = SDL_QUIT;
    SDL_PushEvent(&event);
}
```

---

## 7. AppWindow Layering Above SDL

**Problem:** SDL creates its own `UIWindow` with an OpenGL view. The SwiftUI Library UI must appear above it, and the Player controls must overlay it while passing non-control touches through.

**Solution (`AppWindow.swift`):** A single `UIWindow` is created at `windowLevel = .normal + 1` (above SDL's window) and installed via `+load` (before `main()` runs). It switches between opaque (Library mode) and transparent (Player mode). Theme changes (dark/light/auto) are observed via `withObservationTracking` and applied at the window level via `overrideUserInterfaceStyle`.

---

## Summary

The architecture can be summarized as:

| Constraint                 | Workaround                                      |
| -------------------------- | ----------------------------------------------- |
| SDL can't restart          | Persistent window/EGL/AL, session loop          |
| Ruby can't restart         | Keep VM alive, reset state between sessions     |
| Main thread blocked by SDL | Pump CFRunLoop manually                         |
| No C++→Swift callbacks     | C function pointer callbacks (dispatch to main) |
| No direct engine kill      | Inject SDL_QUIT event                           |
| SDL owns a UIWindow        | Float SwiftUI window above it                   |

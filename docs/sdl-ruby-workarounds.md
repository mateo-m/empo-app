# SDL & Ruby 1.8 Lifecycle Workarounds

## Why This Exists

The iOS port of mkxp-z runs multiple game sessions within a single process. Two fundamental constraints make this non-trivial:

1. **SDL cannot be restarted** — `SDL_Init`/`SDL_Quit` and window/GL context creation are designed for a single process lifetime.
2. **Ruby 1.8 cannot be restarted** — `ruby_init()` and `ruby_cleanup()` are one-shot operations; calling `ruby_cleanup()` corrupts internal state and a subsequent `ruby_init()` crashes with SIGSEGV.

These constraints cascade into every layer of the architecture.

---

## 1. Persistent SDL Window, GL Context, and OpenAL Device

**Problem:** SDL creates an OpenGL window on `SDL_Init`. Destroying and recreating it between game sessions causes GL context issues on iOS.

**Solution (`main.cpp`):** The SDL window, GL context, and OpenAL device are created **once** and reused across all game sessions.

```cpp
// Created once, persist for the process lifetime
SDL_Window *persistWin = SDL_CreateWindow(...);
SDL_GLContext persistGLCtx = initGL(persistWin, ...);
ALCdevice *persistAlcDev = alcOpenDevice(0);
ALCcontext *persistAlcCtx = alcCreateContext(persistAlcDev, 0);
```

At the end of each session, the GL and AL contexts are **detached** from the RGSS thread (not destroyed), so the next session's thread can claim them:

```cpp
// Don't destroy — just detach from the dying thread
alcMakeContextCurrent(NULL);
SDL_GL_MakeCurrent(persistWin, NULL);
```

### Screen FBO Capture

On iOS, SDL creates a non-zero FBO backed by `CAEAGLLayer`. This ID is captured **once** right after context creation and reused forever. Re-querying `GL_FRAMEBUFFER_BINDING` on subsequent sessions would return 0 (because `SharedState::finiInstance` deleted all game FBOs), which is wrong.

```cpp
static GLuint s_iosScreenFBO = 0;
// Captured once:
glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
s_iosScreenFBO = static_cast<GLuint>(fbo);
```

---

## 2. The `while(true)` Game Session Loop

**Problem:** Since SDL and Ruby can't be torn down and rebuilt, we can't simply exit `main()` and re-enter it.

**Solution (`main.cpp`):** A `while(true)` loop on the main thread manages game sessions. Each iteration spawns a new RGSS thread for the game, waits for it to finish, then loops back to wait for the next game selection.

```
main thread:  SDL_Init → create window → while(true) { wait for game → spawn RGSS thread → wait for thread → cleanup → continue }
RGSS thread:  load game → run Ruby → exit thread
```

Between sessions:

- Stale SDL events (especially `SDL_QUIT` from the previous session) are flushed
- All input state arrays are zeroed
- The framebuffer is cleared to black to prevent flashing the last frame
- Bridge state is reset

---

## 3. Ruby 1.8 VM Kept Alive Across Sessions

**Problem (`binding-mri.cpp`):** `ruby_cleanup()` partially destructs the VM. A subsequent `ruby_init()` doesn't fully reinitialize it, causing SIGSEGV on the second game session.

**Solution:** A `static bool rubyVMInitialized` guard ensures `ruby_init()` and all `Init_*` extension calls happen exactly once. `ruby_cleanup(0)` is skipped entirely on iOS.

On subsequent sessions, the VM is manually patched:

1. **GC stack pointer** (`rb_gc_stack_start`): Ruby 1.8's GC scans the thread stack for object references. When the RGSS thread changes between sessions, the old stack is unmapped. The GC stack base must be updated to point at the new thread's stack.

   ```cpp
   volatile VALUE stack_anchor = Qnil;
   rb_gc_stack_start = (VALUE *)&stack_anchor;
   ```

2. **Exception state**: Leftover `$!` from the previous session is cleared. `$@` is NOT set when `$!` is nil — Ruby 1.8 raises `ArgumentError` in that case.

3. **Loaded features**: `$LOADED_FEATURES` and `$"` are cleared so `require` works fresh in the new session.

---

## 4. Ruby 1.8 Stack Size

**Problem:** Ruby 1.8's GC scans the **entire** thread stack (`mark_locations_array`). The default 512KB pthread stack on iOS is insufficient and causes SIGBUS when GC hits the stack guard page.

**Solution:** The RGSS thread is created with a 4MB stack (matching the default main-thread stack size on Apple platforms):

```cpp
SDL_Thread *rgssThread = SDL_CreateThreadWithStackSize(
    rgssThreadFun, "rgss", 4 * 1024 * 1024, &rtData);
```

---

## 5. Run Loop Pumping While Waiting

**Problem (`ios_bridge.cpp`):** `SDL_main` runs on the main thread on iOS. When the engine is waiting for the user to select a game from the Library UI, UIKit must still be able to render and handle events.

**Solution:** The wait loop pumps `CFRunLoop` manually:

```cpp
while (!s_pathSet.load(std::memory_order_acquire)) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
}
```

This keeps UIKit alive (rendering the SwiftUI Library) while the C++ engine blocks on the main thread.

---

## 6. Callback-Based State Notification

**Problem:** The SwiftUI Library UI and the C++ engine communicate through a C bridge (`ios_bridge.h`). The UI needs to know when the engine changes state (game ready, viewport rect changed, engine terminated).

**Solution (`AppState.swift`, `ios_bridge.cpp`):** The bridge provides callback registration functions that the UI registers once at init. Callbacks fire on the engine thread; Swift dispatches to the main thread for UI updates.

```swift
// Registered once in AppState.init()
mkxp_setGameReadyCallback({ _ in
    DispatchQueue.main.async { AppState.shared.phase = .playing }
}, nil)

mkxp_setEngineTerminatedCallback({ _ in
    DispatchQueue.main.async { GameLibrary.shared.reload() }
}, nil)

mkxp_setGameRectChangedCallback({ x, y, w, h, _ in
    DispatchQueue.main.async { AppState.shared.gameRect = CGRect(...) }
}, nil)
```

The engine calls these callbacks from `mkxp_setGameReady()`, `mkxp_setEngineTerminated()`, and `mkxp_setGameRect()` respectively. The rect callback only fires when the value actually changes.

---

## 7. Engine Termination via SDL_QUIT Injection

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

## 8. AppWindow Layering Above SDL

**Problem:** SDL creates its own `UIWindow` with an OpenGL view. The SwiftUI Library UI must appear above it, and the Player controls must overlay it while passing non-control touches through.

**Solution (`AppWindow.swift`):** A single `UIWindow` is created at `windowLevel = .normal + 1` (above SDL's window) and installed via `+load` (before `main()` runs). It switches between opaque (Library mode) and transparent (Player mode). Theme changes (dark/light/auto) are observed via `withObservationTracking` and applied at the window level via `overrideUserInterfaceStyle`.

---

## Summary

The architecture can be summarized as:

| Constraint                 | Workaround                                 |
| -------------------------- | ------------------------------------------ |
| SDL can't restart          | Persistent window/GL/AL, session loop      |
| Ruby 1.8 can't restart     | Keep VM alive, patch GC stack, clear state |
| Ruby 1.8 small stack       | 4MB RGSS thread stack                      |
| Main thread blocked by SDL | Pump CFRunLoop manually                    |
| No C++→Swift callbacks     | C function pointer callbacks (dispatch to main) |
| No direct engine kill      | Inject SDL_QUIT event                      |
| SDL owns a UIWindow        | Float SwiftUI window above it              |

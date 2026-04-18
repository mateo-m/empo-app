# Pause / Resume

## Overview

The app supports two pause modes:

1. **Manual pause** — user taps the pause button in the toolbar. The engine suspends, the UI returns to the library, and the game card shows a pause indicator. Tapping the card resumes with a hero zoom animation.
2. **Background pause** — the app moves to the background. The engine suspends silently; the player view stays mounted. Auto-resumes when the app returns to the foreground.

Both modes share the same engine-side mechanism (condvar block), but differ in how the UI responds.

---

## Engine-Side Pause

### Flow

1. UI calls `mkxp_requestPause()` — sets an atomic flag.
2. On the next frame, `GraphicsPrivate::checkPause()` sees the flag and:
   - Captures a snapshot of the front buffer (see below).
   - Calls `mkxp_checkPause()`, which pauses all `AL_PLAYING` audio sources, fires the paused callback, and blocks on a condvar.
3. The engine thread is now frozen. No rendering, no audio, no script execution.
4. UI calls `mkxp_requestResume()` — signals the condvar.
5. `mkxp_checkPause()` unblocks, resumes the paused audio sources, and returns.
6. `checkPause()` resets frame timing so the FPS limiter doesn't try to catch up.

### Audio: the context must stay current

Apple's iOS OpenAL implementation triggers audio hardware activity the moment a context is restored via `alcMakeContextCurrent(ctx)` — regardless of source state, suspend calls, or listener gain. This caused an audible blip when quitting a paused game to start another.

The fix: **never touch the OpenAL context**. No `alcMakeContextCurrent(NULL)`, no `alcMakeContextCurrent(ctx)`. The context stays current the entire time. We pause/resume individual sources instead:

- **On pause:** `alSourcePause()` each `AL_PLAYING` source (tracked by ID).
- **On resume:** `alSourcePlay()` the tracked sources — audio picks up where it left off.
- **On terminate:** sources stay paused (silent) until `finiInstance()` deletes them.

### Terminate while paused

`mkxp_requestTerminate()` also unblocks the condvar. It sets `s_terminateRequested`, clears the pause flags, signals the condvar, and pushes `SDL_QUIT`. The resume path in `mkxp_checkPause()` checks the terminate flag and skips audio restoration — the sources stay silent until cleanup.

---

## Snapshot: Static Double for SwiftUI Transitions

### The problem

The SDL window is a fullscreen `UIWindow` that sits behind the SwiftUI layer. It can't be moved, resized, or made to participate in SwiftUI view transitions. When the hero zoom animation needs to animate from a game card into the player, there's nothing at the destination — the SDL view isn't part of the SwiftUI view hierarchy, and the PlayerView is a transparent controls overlay.

### The pattern

This is a standard technique for bridging non-native rendering surfaces (OpenGL, Metal, video players) with UIKit/SwiftUI transitions. Apple's own APIs use the same approach — `UIView.snapshotView(afterScreenUpdates:)` exists for this purpose, and the system uses frozen snapshots during app switcher animations and rotation transitions.

The idea: **capture the last rendered frame, animate the static image, swap in the live surface when the animation ends.**

### Implementation

**Capture (engine thread, `graphics.cpp`):**

Before the engine blocks on the condvar, `GraphicsPrivate::checkPause()` reads the front buffer via `glReadPixels`:

```
TEXFBO &fb = screen.getPP().frontBuffer();
gl.ReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
mkxp_setSnapshot(pixels.data(), w, h);
```

We read from the internal FBO (the engine's render target), not FBO 0 (the screen), because iOS gives undefined content for the on-screen framebuffer after `swapBuffers`. The engine's 2D projection maps Y top-to-bottom, so the pixel data is already in the correct orientation — no vertical flip needed.

**Storage (bridge, `ios_bridge.cpp`):**

`mkxp_setSnapshot()` copies the RGBA data into a `std::vector<unsigned char>`. `mkxp_getSnapshotRGBA()` returns a pointer to the buffer. The data is valid until the next pause or `mkxp_resetBridgeState()`.

**Retrieval (Swift, `AppState.swift`):**

The paused callback runs on the engine thread. It reads the snapshot via `mkxp_getSnapshotRGBA()`, converts it to a `CGImage` → `UIImage`, and dispatches to main to store it as `engineState.pauseSnapshot`.

**Display (Swift, `GameLoadingView.swift`):**

When `GameLoadingView` detects a resume (snapshot is non-nil), it shows the snapshot positioned at `engineState.gameRect` — the exact viewport position the engine was using, accounting for portrait layout and safe areas. This makes the hero zoom appear to zoom into the live game.

**Cleanup (Swift, `PlayerView.onAppear`):**

When PlayerView appears, it picks up `engineState.pauseSnapshot`, copies it into local `@State`, and fades it out over 0.35s. After the fade, both the local copy and `engineState.pauseSnapshot` are cleared. The live SDL rendering is now visible underneath.

### Portrait layout

In portrait mode, the game renders at the top of the screen with touch controls below. The snapshot must be placed at `engineState.gameRect` (not stretched to fill the screen) to match this layout. `gameRect` is in logical points and already accounts for safe area insets, aspect ratio, and vertical alignment settings.

---

## Resume Animation Timing

The resume transition has two stages that use the snapshot in sequence for visual continuity:

### Stage 1: Hero zoom (GameLoadingView)

The hero zoom from game card → GameLoadingView requires the library to be visible. `resume()` delays the phase change so the library stays mounted:

1. `handleGameTap` calls `appState.resume()` then `path.append(game)`.
2. `resume()` immediately clears `pausedGame` and calls `mkxp_requestResume()` (engine unblocks), but does **not** set `phase = .playing` yet.
3. `path.append(game)` pushes `GameLoadingView` with the hero zoom. The destination shows the snapshot at `engineState.gameRect` on a black background.

### Stage 2: Handoff to PlayerView

4. After 0.35s (matching the hero zoom duration), `resume()` sets `phase = .playing`.
5. The library hides (opacity 0), and PlayerView appears. PlayerView picks up the same snapshot from `engineState.pauseSnapshot` and shows it at `engineState.gameRect` as an overlay — **with controls and toolbar visible alongside it**.
6. The snapshot fades out over 0.35s, revealing the live SDL rendering underneath.

The snapshot appears in both views at the same `engineState.gameRect` position, so the handoff from GameLoadingView → PlayerView is seamless. Controls are visible the moment PlayerView mounts.

---

## Key Files

| File | Role |
|------|------|
| `mkxp-z/src/display/graphics.cpp` | `GraphicsPrivate::checkPause()` — snapshot capture and pause delegation |
| `mkxp-z/src/ios_bridge.cpp` | Condvar, audio pause/resume, snapshot storage |
| `mkxp-z/src/ios_bridge.h` | Bridge API declarations |
| `ios/Empo/src/App/PauseManager.swift` | User-initiated pause/resume state, `requestPause()`, `resume()`, snapshot ownership |
| `ios/Empo/src/App/AppState.swift` | `returnToLibrary()`, paused callback registration, snapshot conversion |
| `ios/Empo/src/App/EngineState.swift` | Background pause/resume (`requestBackgroundPause()`, `resumeFromBackground()`) |
| `ios/Empo/src/Library/GameLoadingView.swift` | Snapshot at `engineState.gameRect` during hero zoom (stage 1) |
| `ios/Empo/src/Library/GameLibraryView.swift` | `handleGameTap()` — resume flow entry point |
| `ios/Empo/src/Player/PlayerView.swift` | Snapshot fade-out overlay with controls (stage 2), pause button, quit button |
| `ios/Empo/src/App/RootView.swift` | Phase-based visibility (library vs. player), background pause triggers |

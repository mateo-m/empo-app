---
title: Pause and resume
description: The two pause modes, and the frozen-frame snapshots that bridge the SDL window into SwiftUI transitions.
---

## Overview

The app has two pause modes:

1. **Manual pause** - the user taps the pause button in the toolbar. The engine suspends, the UI returns to the library, and the game card shows a pause indicator. A tap on the card resumes the game with a hero zoom animation.
2. **Background pause** - the app moves to the background. The engine suspends silently, and the player view stays mounted. The game resumes automatically when the app returns to the foreground.

Both modes use the same engine-side mechanism (a condvar block). They differ in how the UI responds.

---

## Engine-side pause

### Flow

1. The UI calls `mkxp_requestPause()`. This sets an atomic flag.
2. On the next frame, `GraphicsPrivate::checkPause()` sees the flag and:
   - Captures a snapshot of the front buffer (see below).
   - Calls `mkxp_checkPause()`, which pauses all `AL_PLAYING` audio sources, fires the paused callback, and blocks on a condvar.
3. The engine thread is now frozen. No rendering, no audio, no script execution.
4. The UI calls `mkxp_requestResume()`. This signals the condvar.
5. `mkxp_checkPause()` unblocks, resumes the paused audio sources, and returns.
6. `checkPause()` resets frame timing so the FPS limiter does not try to catch up.

### Audio: the context must stay current

Apple's iOS OpenAL implementation starts audio hardware activity the moment `alcMakeContextCurrent(ctx)` restores a context. Source state, suspend calls, and listener gain do not matter. This caused an audible blip when the user quit a paused game to start another.

The fix: **never touch the OpenAL context**. No `alcMakeContextCurrent(NULL)`, no `alcMakeContextCurrent(ctx)`. The context stays current the entire time. We pause and resume individual sources instead:

- **On pause:** call `alSourcePause()` on each `AL_PLAYING` source (tracked by ID).
- **On resume:** call `alSourcePlay()` on the tracked sources. Audio continues where it stopped.
- **On terminate:** sources stay paused (silent) until `finiInstance()` deletes them.

### Terminate while paused

`mkxp_requestTerminate()` also unblocks the condvar. It sets `s_terminateRequested`, clears the pause flags, signals the condvar, and pushes `SDL_QUIT`. The resume path in `mkxp_checkPause()` checks the terminate flag and skips audio restoration. The sources stay silent until cleanup.

---

## Snapshot: static double for SwiftUI transitions

### The problem

The SDL window is a fullscreen `UIWindow` behind the SwiftUI layer. The app cannot move it, resize it, or include it in SwiftUI view transitions. When the hero zoom animation goes from a game card into the player, there is nothing at the destination. The SDL view is not part of the SwiftUI view hierarchy, and the PlayerView is a transparent controls overlay.

### The pattern

Capture the last rendered frame. Animate the static image. Swap in the live surface when the animation ends. Apple uses the same technique for the app switcher and rotation transitions, and exposes it as `UIView.snapshotView(afterScreenUpdates:)`. It is the standard way to bridge a non-native rendering surface (OpenGL, Metal, video players) into UIKit/SwiftUI transitions.

### Implementation

**Capture (engine thread, `graphics.cpp`):**

Before the engine blocks on the condvar, `GraphicsPrivate::checkPause()` reads the front buffer via `glReadPixels`:

```cpp
TEXFBO &fb = screen.getPP().frontBuffer();
gl.ReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
mkxp_setSnapshot(pixels.data(), w, h);
```

We read from the internal FBO, the engine's render target, and not from FBO 0, the screen. After `swapBuffers`, iOS leaves the on-screen framebuffer with undefined content. The engine's 2D projection maps Y from top to bottom, so the pixel data is already in the correct orientation. No vertical flip is needed.

**Storage (bridge, `app_bridge.cpp`):**

`mkxp_setSnapshot()` copies the RGBA data into a `std::vector<unsigned char>`. A mutex guards the vector. The app reads it out through a two-call copy API: `mkxp_getSnapshotSize()` gives the dimensions, and `mkxp_copySnapshotRGBA()` copies bytes into a caller-owned buffer. We retired the previous pointer-returning API because its pointers dangled across threads.

**Retrieval (Swift, `AppState.swift`):**

The paused callback runs on the engine thread. It reads the snapshot via `mkxp_getSnapshotSize()` + `mkxp_copySnapshotRGBA()`, converts the bytes to a `CGImage` -> `UIImage`, and dispatches to the main thread to store it as `pauseManager.pauseSnapshot`.

**Display (Swift, `GameLoadingView.swift`):**

When `GameLoadingView` detects a resume (the snapshot is non-nil), it shows the snapshot at `engineState.gameRect`. This is the exact viewport position the engine used, with portrait layout and safe areas included. The hero zoom then appears to zoom into the live game.

**Cleanup (Swift, `PlayerView.onAppear`):**

When PlayerView appears, it picks up `pauseManager.pauseSnapshot`, copies it into local `@State`, and fades it out over 0.35s. After the fade, the view clears the local copy and `pauseManager.pauseSnapshot`. The live SDL rendering is now visible underneath.

### Portrait layout

In portrait mode, the game renders at the top of the screen with touch controls below. Place the snapshot at `engineState.gameRect` to match this layout. Do not stretch it to fill the screen. `gameRect` is in logical points and already includes safe area insets, aspect ratio, and vertical alignment settings.

---

## Resume animation timing

The resume transition has two stages. Both use the snapshot in sequence for visual continuity:

### Stage 1: hero zoom (GameLoadingView)

The hero zoom from game card → GameLoadingView requires a visible library. `resume()` delays the phase change so the library stays mounted:

1. `handleGameTap` calls `appState.resume()` then `path.append(game)`.
2. `resume()` immediately clears `pausedGame` and calls `mkxp_requestResume()`. The engine unblocks. `resume()` does **not** set `phase = .playing` yet.
3. `path.append(game)` pushes `GameLoadingView` with the hero zoom. The destination shows the snapshot at `engineState.gameRect` on a black background.

### Stage 2: handoff to PlayerView

1. After 0.35s (the hero zoom duration), `resume()` sets `phase = .playing`.
2. The library hides (opacity 0), and PlayerView appears. PlayerView picks up the same snapshot from `engineState.pauseSnapshot` and shows it at `engineState.gameRect` as an overlay, **with controls and the toolbar visible next to it**.
3. The snapshot fades out over 0.35s. The live SDL rendering shows underneath.

The snapshot sits at the same `engineState.gameRect` in both views, so the handoff from GameLoadingView to PlayerView lands without a visual jump. Controls render the moment PlayerView mounts.

---

## Key files

| File                                           | Role                                                                                |
| ---------------------------------------------- | ----------------------------------------------------------------------------------- |
| `mkxp-z-apple-mobile/src/display/graphics.cpp` | `GraphicsPrivate::checkPause()` - snapshot capture and pause delegation             |
| `mkxp-z-apple-mobile/src/app_bridge.cpp`       | Condvar, audio pause/resume, snapshot storage                                       |
| `mkxp-z-apple-mobile/src/app_bridge.h`         | Bridge API declarations                                                             |
| `ios/Empo/src/App/PauseManager.swift`          | User-initiated pause/resume state, `requestPause()`, `resume()`, snapshot ownership |
| `ios/Empo/src/App/AppState.swift`              | `returnToLibrary()`, paused callback registration, snapshot conversion              |
| `ios/Empo/src/App/EngineState.swift`           | Background pause/resume (`requestBackgroundPause()`, `resumeFromBackground()`)      |
| `ios/Empo/src/Library/GameLoadingView.swift`   | Snapshot at `engineState.gameRect` during hero zoom (stage 1)                       |
| `ios/Empo/src/Library/GameLibraryView.swift`   | `handleGameTap()` - resume flow entry point                                         |
| `ios/Empo/src/Player/PlayerView.swift`         | Snapshot fade-out overlay with controls (stage 2), pause button, quit button        |
| `ios/Empo/src/App/RootView.swift`              | Phase-based visibility (library vs. player), background pause triggers              |

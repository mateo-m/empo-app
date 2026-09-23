---
title: Pause and resume
description: The two pause modes, and the frozen-frame snapshots that bridge the game window into SwiftUI transitions.
---

## Overview

The app has two pause modes:

1. **Manual pause.** The user taps the pause button in the toolbar. The engine stops, the UI goes back to the library, and the game card shows a pause indicator. A tap on the card resumes the game with a hero zoom animation.
2. **Background pause.** The app moves to the background. The engine stops with no UI change, and the player view stays mounted. The game resumes when the app comes back to the foreground.

Both modes use the same engine pause, a block on a condition variable. They differ in how the UI responds.

The app calls the `gamecore_*` functions. `GameCoreForwarders.c` sends each call to the core of the game, so both cores use the same flow.

---

## Engine pause in the RPG Maker core

### Flow

1. The UI calls `gamecore_requestPause()`. This sets an atomic flag.
2. On the next frame, `GraphicsPrivate::checkPause()` in `graphics.cpp` sees the flag. It captures a snapshot (see below), then calls `mkxp_checkPause()`.
3. `mkxp_checkPause()` pauses all `AL_PLAYING` audio sources, calls the paused callback, and blocks on the condition variable.
4. The engine thread is now frozen. No rendering, no audio, no script execution.
5. The UI calls `gamecore_requestResume()`. This signals the condition variable.
6. `mkxp_checkPause()` unblocks, resumes the paused audio sources, and returns.
7. `checkPause()` resets the frame timing, so the FPS limiter does not try to catch up.

### Audio: the context must stay current

Apple's iOS OpenAL implementation starts audio hardware activity when `alcMakeContextCurrent(ctx)` restores a context. Source state, suspend calls, and listener gain do not change this. The result is an audible blip on resume.

So the engine **never touches the OpenAL context**. No `alcMakeContextCurrent(NULL)`, no `alcMakeContextCurrent(ctx)`. The context stays current the entire time. The engine pauses and resumes individual sources:

- **On pause:** call `alSourcePause()` on each `AL_PLAYING` source, tracked by ID.
- **On resume:** call `alSourcePlay()` on the tracked sources. Audio continues where it stopped.

---

## Engine pause in the PSDK core

`psdk_app_bridge.cpp` holds the same flow:

1. `psdk_requestPause()` sets an atomic flag.
2. SFML calls `psdk_frame_rendered` one line before it swaps the buffers. When the flag is set, `captureSnapshot()` reads the game picture from the default framebuffer.
3. The PSDK core cannot pause single sources, because SFMLAudio keeps no list of them. It pauses the whole OpenAL Soft device with `alcDevicePauseSOFT`.
4. It calls the paused callback and waits on the condition variable.
5. `psdk_requestResume()` clears the flag, signals the condition variable, and clears the snapshot. The device resumes with `alcDeviceResumeSOFT`.

---

## Snapshot: a still copy for SwiftUI transitions

### The problem

The game window is a fullscreen `UIWindow` behind the SwiftUI layer. The app cannot move it, resize it, or include it in SwiftUI view transitions. When the hero zoom animation goes from a game card into the player, there is nothing at the destination. The game window is not part of the SwiftUI view hierarchy, and `PlayerView` is a transparent controls overlay.

### The pattern

Capture the last frame. Animate the still image. Show the live game when the animation ends. Apple uses the same technique for the app switcher and rotation transitions, and gives it to apps as `UIView.snapshotView(afterScreenUpdates:)`.

### Implementation

**Capture in the RPG Maker core (`graphics.cpp`):**

Before the engine blocks, `GraphicsPrivate::checkPause()` reads `lastPresentedFrame` with `glReadPixels` and stores it with `mkxp_setSnapshot()`. On the first frame of a session, it reads the front buffer.

It reads the last presented frame, not the frame it just drew. A scene change can run Ruby for a long time with no frame. The first frame after that belongs to the new scene, and an empty scene is black.

It never reads FBO 0, the screen. After `swapBuffers`, iOS leaves the on-screen framebuffer with undefined content. The engine's 2D projection maps Y from top to bottom, so the pixel data is already in the correct orientation.

**Storage (`app_bridge.cpp`, `psdk_app_bridge.cpp`):**

Each core copies the RGBA data into a `std::vector<unsigned char>`. A mutex guards the vector. The app reads it with two calls: `gamecore_getSnapshotSize()` gives the dimensions, and `gamecore_copySnapshotRGBA()` copies the bytes into a buffer that the app owns.

**Retrieval (Swift, `EngineSessionCoordinator.swift`):**

The paused callback runs on the engine thread. `capturePauseSnapshot()` reads the snapshot and converts the bytes to a `CGImage`, then to a `UIImage`. The callback then goes to the main thread. `AppState.handlePause(snapshot:)` stores the image as `pauseManager.pauseSnapshot`. It ignores a background pause.

**Display (Swift, `PauseSnapshotOverlay.swift`):**

`GameLoadingView` and `PlayerView` both show the snapshot with `PauseSnapshotOverlay` at `engineState.gameRect`. This is the exact viewport position that the engine uses, with the portrait layout and safe areas included.

**Cleanup (Swift, `PlayerView`):**

When `PlayerView` appears, it copies `pauseManager.pauseSnapshot` into a local `@State`. It starts the fade when `pauseManager.snapshotCanFade` becomes true. The fade uses `Motion.standard`. When the fade completes, the view clears the local copy, `pauseManager.pauseSnapshot`, and `snapshotCanFade`. The live game is now visible under it.

### Portrait layout

In portrait mode, the game renders at the top of the screen, with the touch controls below. Put the snapshot at `engineState.gameRect` to match this layout. Do not stretch it to fill the screen. `gameRect` is in logical points and already includes the safe area insets, the aspect ratio, and the vertical alignment settings.

---

## Resume animation timing

The resume transition has two stages. Both show the same snapshot, so the picture does not jump.

### Stage 1: hero zoom (`GameLoadingView`)

The hero zoom from the game card to `GameLoadingView` needs a visible library. So `resumePausedGame()` does not change the phase at once:

1. `handleGameTap` calls `appState.resumePausedGame()`, then pushes the game.
2. `resumePausedGame()` clears `pausedGame`, sets `snapshotCanFade` to false, and calls `gamecore_requestResume()`. The engine unblocks. The phase does not change yet.
3. The push shows `GameLoadingView` with the hero zoom. The destination shows the snapshot at `engineState.gameRect` on a black background.

### Stage 2: handoff to `PlayerView`

1. After 350 ms, the hero zoom duration, `resumePausedGame()` sets `phase = .playing`.
2. The library hides, and `PlayerView` appears. `PlayerView` shows the same snapshot at `engineState.gameRect`. The controls stay hidden until the fade starts.
3. The engine draws a frame, and `coordinatorFrameRendered()` sets `snapshotCanFade` to true. If no frame comes in 300 ms, a backup timer in `resumePausedGame()` sets it.
4. The snapshot fades out, and the controls fade in. The live game shows under the snapshot.

---

## Key files

| File                                           | Role                                                                          |
| ---------------------------------------------- | ----------------------------------------------------------------------------- |
| `mkxp-z-apple-mobile/src/display/graphics.cpp` | `GraphicsPrivate::checkPause()`: snapshot capture in the RPG Maker core        |
| `mkxp-z-apple-mobile/src/app_bridge.cpp`       | Condition variable, audio pause and resume, snapshot storage                  |
| `ios/Dependencies/psdk/psdk_app_bridge.cpp`    | The same pause, audio, and snapshot code for the PSDK core                    |
| `ios/Empo/src/App/GameCoreForwarders.c`        | Sends each `gamecore_*` call to the core of the game                          |
| `ios/Empo/src/App/PauseManager.swift`          | `pausedGame`, `pauseSnapshot`, `snapshotCanFade`                              |
| `ios/Empo/src/App/AppState.swift`              | `requestPause()`, `handlePause(snapshot:)`, `resumePausedGame()`             |
| `ios/Empo/src/App/EngineSessionCoordinator.swift` | Paused callback, `capturePauseSnapshot()`, frame-rendered callback         |
| `ios/Empo/src/App/EngineState.swift`           | Background pause and resume (`requestBackgroundPause()`, `resumeFromBackground()`) |
| `ios/Empo/src/Design/PauseSnapshotOverlay.swift` | Shows the snapshot at `engineState.gameRect`                                |
| `ios/Empo/src/Library/GameLoadingView.swift`   | Snapshot during the hero zoom (stage 1)                                       |
| `ios/Empo/src/Library/GameLibraryView.swift`   | `handleGameTap()`: the start of the resume flow                               |
| `ios/Empo/src/Player/PlayerView.swift`         | Snapshot fade-out with the controls (stage 2), pause button                   |
| `ios/Empo/src/App/RootView.swift`              | Library or player by phase, background pause triggers                         |

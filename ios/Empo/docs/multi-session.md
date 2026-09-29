---
title: Multi-session
description: How each game runs in its own process, so any game can follow any other.
---

## Status

Each game runs in its own process. The app does not load a core. It starts the `GameProcess` extension (ExtensionKit, iOS 26), and the extension opens one core and plays one game. To end a game, the app sends `quit`, and the extension calls `_exit(0)`. The next game gets a new process, so no Ruby VM, class, or SFML state stays behind. Any game can start next, on any core:

- A paused game gives its place to the next game that the user taps. The library asks first, because the paused game loses its progress that is not saved.
- A game that ends shows a "Back to Library" button.
- The More sheet shows "Quit" under "Pause". Quit asks first, then ends the process and goes back to the library.
- The loading screen shows "Stop Loading".

`GameProcessHost.swift` starts and ends the extension. It shows the game in an `EXHostViewController` behind the app's views. `GameProcessClient.m` implements the `gamecore_*` calls of the app as XPC messages to `GameProcessService.m` in the extension. The getters answer from the last status that the extension sent.

The app waits until the old process ended, with a limit of 2 seconds, before it starts a new one. When the extension stops without a `quit`, the app shows the game as stopped. A paused game that loses its process closes.

## Why this is hard

An iOS app cannot stop itself and start again. Android players such as JoiPlay stop the process after each game with `Process.killProcess()`. On iOS, the app must clean the state of the Ruby VM between games:

- Game A defines `class Foo < Bar`. The class stays in the constant table of the VM.
- Game B runs in the same VM and defines `class Foo < Baz`. Ruby raises `TypeError: superclass mismatch for class Foo`.
- Two games can leave any set of classes, patches, aliases and disposed RGSS objects behind. Nobody can know that set in advance.

A cleanup between sessions worked for some pairs of games with the same Ruby version. It failed on larger sets of games, and on games with different Ruby versions.

A flow that fails at random is worse than a restart. A process for each game makes the cleanup unnecessary. ExtensionKit lets an iOS app start a process of its own, and the app can end that process without ending itself.

## What happens when a game ends

When Ruby raises `SystemExit` or `Reset` in the RPG Maker XP, VX and VX Ace core:

1. `binding-mri.cpp` catches the exception and calls `mkxp_setEngineExitedCleanly()`.
2. `EngineHost::runSession` in `main.cpp` waits for `rqTermAck` (`waitForRGSSAck`), then stops the event thread and clears the framebuffer.
3. `mkxp_setEngineTerminated()` calls the iOS callback.
4. The `AppState` callback sets `phase` to `.ended`. `GameLoadingView` takes the place of the game and says that the game closed. For an error, it says that the game stopped.
5. The screen shows "Back to Library". It ends the game process.
6. On the next launch, `CrashTracker.consumeRecovery()` deletes the `.session-active` markers on disk. Without this step, each launch would say that the last game did not exit cleanly.

The app sets the callback with `gamecore_setEngineTerminatedCallback`, which goes to the core of the game. The PSDK and MV/MZ cores call it too. A game that ends before its first frame gets the same screen. For an error, the screen says that the game did not start.

## Scripts that try to quit the process

Two parts of `scripts/preload/platform_compat.rb` in the engine keep a quit inside this flow:

- **`Kernel.exit!` and `Process.exit!` call `Kernel.exit`.** Pokemon Essentials' `pbExit` and many forks call `exit!`. On iOS, `exit!` calls C `_exit(status)`, and the game process ends before the engine can show the end screen. `exit` raises `SystemExit`, and the engine catches it. App Store guideline 2.5.1 also forbids an app that stops its own process.
- **`Thread.critical` and `Thread.critical=` do nothing on Ruby 1.9 and later.** Old RGSS code puts `Marshal.load` and save file I/O in `Thread.critical = true` blocks. Ruby 1.9 removed both methods. Without this part, the game raises `NoMethodError` while it quits, and `SharedState::finiInstance()` crashes while it stops the graphics.

See [`multi-ruby.md`](multi-ruby.md) for the Ruby versions.

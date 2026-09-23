---
title: Multi-session
description: Why Empo plays one game for each process, and what must change before it can play a second game without a restart.
---

## Status

Empo plays one game for each process. This applies to both game cores. When a game ends, Empo shows "The game ended." and asks the user to close Empo from the app switcher and open it again. It does not go back to the library.

## Why this is hard

An iOS app cannot stop itself and start again. Android players such as JoiPlay stop the process after each game with `Process.killProcess()`. On iOS, the app must clean the state of the Ruby VM between games:

- Game A defines `class Foo < Bar`. The class stays in the constant table of the VM.
- Game B runs in the same VM and defines `class Foo < Baz`. Ruby raises `TypeError: superclass mismatch for class Foo`.
- Two games can leave any set of classes, patches, aliases and disposed RGSS objects behind. Nobody can know that set in advance.

A cleanup between sessions worked for some pairs of games with the same Ruby version. It failed on larger sets of games, and on games with different Ruby versions.

Empo shows a clear message and asks for a restart. A flow that fails at random is worse. Two changes can make a second game possible:

- Start each game in its own process.
- Move all the VM state of a session into a container that the engine can reset fully.

## What happens when a game ends

When Ruby raises `SystemExit` or `Reset` in the RPG Maker core:

1. `binding-mri.cpp` catches the exception and calls `mkxp_setEngineExitedCleanly()`.
2. `EngineHost::runSession` in `main.cpp` waits for `rqTermAck` (`waitForRGSSAck`), then stops the event thread and clears the framebuffer.
3. `mkxp_setEngineTerminated()` calls the iOS callback.
4. The `AppState` callback sets `errorMessage` to "The game ended.", and `RootView` shows the alert.
5. The user taps OK. The alert closes, but `phase` keeps its value, so the view does not change.
6. The user closes the app from the app switcher.
7. On the next launch, `CrashTracker.consumeRecovery()` deletes the `.session-active` markers on disk. Without this step, each launch would say that the last game did not exit cleanly.

The app sets the callback with `gamecore_setEngineTerminatedCallback`, which goes to the core of the game. The PSDK core calls it too, so a PSDK game shows the same alert.

## Scripts that try to quit the process

Two parts of `scripts/preload/platform_compat.rb` in the engine keep a quit inside this flow:

- **`Kernel.exit!` and `Process.exit!` call `Kernel.exit`.** Pokemon Essentials' `pbExit` and many forks call `exit!`. On iOS, `exit!` calls C `_exit(status)`, and the app closes before the engine knows. `exit` raises `SystemExit`, and the engine catches it. App Store guideline 2.5.1 also forbids an app that stops its own process.
- **`Thread.critical` and `Thread.critical=` do nothing on Ruby 1.9 and later.** Old RGSS code puts `Marshal.load` and save file I/O in `Thread.critical = true` blocks. Ruby 1.9 removed both methods. Without this part, the game raises `NoMethodError` while it quits, and `SharedState::finiInstance()` crashes while it stops the graphics.

See [`multi-ruby.md`](multi-ruby.md) for the Ruby versions.

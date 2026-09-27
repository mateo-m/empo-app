---
title: Multi-session
description: Why a Ruby game needs a restart before the next game, and why an MV or MZ game does not.
---

## Status

Empo plays one game for each process on the RPG Maker XP, VX and VX Ace core and on the PSDK cores. Nothing can kill a Ruby VM and start a clean one in the same process.

The MV and MZ core is different. Each game is a web page, and WebKit ends the page and all of its JavaScript when the core removes its web view. The core says so with `canKillSession` in its Swift type, and `gamecore_killSession` removes the web view. After that call the process holds nothing of the game, so any game can start next, on any core:

- A paused MV or MZ game gives its place to the next game that the user taps. The library asks first, because the paused game loses its progress that is not saved.
- A paused Ruby game blocks every other game. The library shows "A game is paused".
- An MV or MZ game that ends shows a "Back to Library" button.
- The More sheet of an MV or MZ game shows "Quit" under "Pause". Quit asks first, then kills the game and goes back to the library.

`EmpoCoreOpen` refuses a second core while the open core holds a game that it did not kill, and `openCore` then stops the app.

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

When Ruby raises `SystemExit` or `Reset` in the RPG Maker XP, VX and VX Ace core:

1. `binding-mri.cpp` catches the exception and calls `mkxp_setEngineExitedCleanly()`.
2. `EngineHost::runSession` in `main.cpp` waits for `rqTermAck` (`waitForRGSSAck`), then stops the event thread and clears the framebuffer.
3. `mkxp_setEngineTerminated()` calls the iOS callback.
4. The `AppState` callback sets `phase` to `.ended`. `GameLoadingView` takes the place of the game and says that the game closed. For an error, it says that the game stopped.
5. A core that can kill its session shows "Back to Library". The RPG Maker XP, VX and VX Ace core and the PSDK cores cannot, so the screen asks the user to close Empo from the app switcher and open it again.
6. On the next launch, `CrashTracker.consumeRecovery()` deletes the `.session-active` markers on disk. Without this step, each launch would say that the last game did not exit cleanly.

The app sets the callback with `gamecore_setEngineTerminatedCallback`, which goes to the core of the game. The PSDK and MV/MZ cores call it too. A game that ends before its first frame gets the same screen. For an error, the screen says that the game did not start.

## Scripts that try to quit the process

Two parts of `scripts/preload/platform_compat.rb` in the engine keep a quit inside this flow:

- **`Kernel.exit!` and `Process.exit!` call `Kernel.exit`.** Pokemon Essentials' `pbExit` and many forks call `exit!`. On iOS, `exit!` calls C `_exit(status)`, and the app closes before the engine knows. `exit` raises `SystemExit`, and the engine catches it. App Store guideline 2.5.1 also forbids an app that stops its own process.
- **`Thread.critical` and `Thread.critical=` do nothing on Ruby 1.9 and later.** Old RGSS code puts `Marshal.load` and save file I/O in `Thread.critical = true` blocks. Ruby 1.9 removed both methods. Without this part, the game raises `NoMethodError` while it quits, and `SharedState::finiInstance()` crashes while it stops the graphics.

See [`multi-ruby.md`](multi-ruby.md) for the Ruby versions.

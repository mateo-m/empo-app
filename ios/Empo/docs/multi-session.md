---
title: Multi-session
description: Where a game runs, and how a game process lets any game follow any other.
---

## Status

A game runs in one of two places, which `GameRunner` names:

- `app`: the app opens the core with `dlopen` and runs the engine on its main thread. This is the default.
- `gameProcess`: the app starts the `GameProcess` extension (ExtensionKit, iOS 26), and the extension opens one core and plays one game.

The MV and MZ core always runs in the app. It can end a game there with `gamecore_killSession`, so any game can follow it. The Ruby cores (RPG Maker XP, VX and VX Ace, and PSDK) run in a game process only when the person turns on "Quit and switch games" in the Experimental section of Settings. The section shows only in a build with a Ruby core. The app reads the setting once at launch (`AppSettings.rubyGameRunnerThisLaunch`), because a core that the app opened stays in the app until the app ends.

In a game process, the app sends `quit` to end a game, and the extension calls `_exit(0)`. The next game gets a new process, so no Ruby VM, class, or SFML state stays behind. Any game can start next, on any core:

- A paused game gives its place to the next game that the user taps. The library asks first, because the paused game loses its progress that is not saved.
- A game that ends shows a "Back to Library" button.
- The More sheet shows "Quit" under "Pause". Quit asks first, then ends the process and goes back to the library.
- The loading screen shows "Stop Loading".

A Ruby game that runs in the app cannot end. The screens tell the person to close Empo from the app switcher and open it again.

`EngineSessionCoordinator.openCore` picks the runner and calls `EmpoCoreUseGameProcess`. Every `gamecore_*` call of the app goes through `AppCoreForwarders.c`. In a game process, a forwarder calls the `gameprocess_*` function of the same name in `GameProcessClient.m`, which sends an XPC message to `GameProcessService.m` in the extension. The getters answer from the last status that the extension sent. In the app, a forwarder calls the core that the app opened. `tools/gamecore/generate-core-forwarders.sh` writes the list of the forwarded functions, `GameCoreFunctions.h`, from `cores/GameCore.h`.

`GameProcessHost.swift` starts and ends the extension. It shows the game in an `EXHostViewController` behind the app's views. The app waits until the old process ended, with a limit of 2 seconds, before it starts a new one. When the extension stops without a `quit`, the app shows the game as stopped. A paused game that loses its process closes.

## Where the data lives

A game process can open only its own folder and the app group folder. It cannot open the app's Documents. The app group ID is `group.` plus the bundle ID of the app. `project.yml` sets it in `EMPO_APP_GROUP`, and the app reads it from the `EmpoAppGroup` key in `Info.plist`.

`DataDirectory.documentsRootURL` is the folder that holds `Games`, `Data`, `Fonts`, `Profiles` and the rescue folders. It is `File Provider Storage` in the app group, for both runners, so the setting does not move any data. At the first launch of a build with the app group, the app moves each item of Documents into it. When an item in Documents is a link into the app group, the app moves the item that the link points to, then removes the link. When both folders have a folder with the same name, the app merges the two. When both have a file with the same name, the newer file keeps the name, and the older file moves next to it as `<name>.empo-displaced.bak`, the name that `LegacyDataDrain` gives a displaced copy. The `.bak` end keeps the copy out of the save lists of the games.

AltStore and SideStore add `.` and the team ID to the group name when they sign the app. `DataDirectory.appGroupURL` reads the group names from the app's own signature with `SecTaskCopyValueForEntitlement`, and uses the first one that is the configured name or starts with it and a `.`. LiveContainer runs the app with its own signature, so no group matches, and the root is Documents. When no app group is available, the root is Documents, the game process is not available, and the Files app does not show the data in the Empo location. Settings then shows "Quit and switch games" off and disabled, with a note that says why.

The `FilesProvider` extension shows the root in the Files app, under Locations. It is an `NSFileProviderExtension`, and `NSExtensionFileProviderDocumentGroup` names the app group. `UIFileSharingEnabled` is off, so the Files app does not also show the empty Documents under "On My iPhone". A deleted item goes to `.Trash/<UUID>/` in the root, and the Files app shows it in Recently Deleted. The extension removes trashed items after 30 days.

`CABundleStore` keeps its downloaded certificates in the app group, because the game process reads them.

## Reports

A game process session always writes a session log, also when the debug logs setting is off. The extension sends its stdout and stderr to the log, and writes a backtrace to it on a crash signal. The app adds lines that start with `[empo]` for what it saw, for example a quit or a process that went away (`SessionLogger.note`).

`GameReport` turns a session log into a text file to share. The file starts with the app version, the commit, the device and the game. The log names the core and the runner. The person can share the newest report of a game from "Share report" in its Info sheet. "Share Report" on the error alert and on the screen of a game that stopped shares the report of the last session (`GameReport.last`), which the app keeps across launches.

The debug overlay shows where the game runs. In a game process, it shows the memory of the game process and of the app on separate lines.

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
5. When the game can end, the screen shows "Back to Library", which ends the game. A Ruby game that runs in the app cannot end, so the screen tells the person to close Empo from the app switcher.
6. On the next launch, `CrashTracker.consumeRecovery()` deletes the `.session-active` markers on disk. Without this step, each launch would say that the last game did not exit cleanly.

The app sets the callback with `gamecore_setEngineTerminatedCallback`, which goes to the core of the game. The PSDK and MV/MZ cores call it too. A game that ends before its first frame gets the same screen. For an error, the screen says that the game did not start.

## Scripts that try to quit the process

Two parts of `scripts/preload/platform_compat.rb` in the engine keep a quit inside this flow:

- **`Kernel.exit!` and `Process.exit!` call `Kernel.exit`.** Pokemon Essentials' `pbExit` and many forks call `exit!`. On iOS, `exit!` calls C `_exit(status)`, and the game process ends before the engine can show the end screen. `exit` raises `SystemExit`, and the engine catches it. App Store guideline 2.5.1 also forbids an app that stops its own process.
- **`Thread.critical` and `Thread.critical=` do nothing on Ruby 1.9 and later.** Old RGSS code puts `Marshal.load` and save file I/O in `Thread.critical = true` blocks. Ruby 1.9 removed both methods. Without this part, the game raises `NoMethodError` while it quits, and `SharedState::finiInstance()` crashes while it stops the graphics.

See [`multi-ruby.md`](multi-ruby.md) for the Ruby versions.

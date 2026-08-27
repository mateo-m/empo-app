---
title: Multi-session
description: Why Empo plays one game for each process, which quit paths it removed, and what must change before cross-session play returns.
---

## Status

Cross-session play is **disabled**. After a clean game exit, Empo shows an alert ("close from app switcher to play again"). It does not return to the library. To start a different game, the user must force-close the app and open it again.

The original UX ("drop to library, pick another game in the same process") is gone from the code until Ruby state cleanup is reliable.

## Why this is hard

An iOS app cannot kill itself and start again. Android emulators (JoiPlay) avoid the problem: they call `Process.killProcess()` after each game. On iOS, the app must clean the active Ruby VM's state manually between games:

- Game A defines `class Foo < Bar`. The class lives in the active Ruby's constant table.
- Game B runs in the same VM. It defines `class Foo < Baz`. Ruby raises `TypeError: superclass mismatch for class Foo`.
- The set of leaked classes, monkey-patches, aliases, and disposed RGSS objects across two arbitrary games is unpredictable.

An earlier version cleaned up hard between sessions. It compared constants against a baseline, recorded a singleton-method baseline, used the `MkxpNullMouse` stand-in for leftover globals, and detached disposables from their lists. It worked for a few same-version game pairs. It failed on wider game sets, above all when two games used different Ruby versions, because the data structures differ.

The decision: show a clear alert that asks the player to close the app, rather than a half-working flow that fails at random. Two later options can bring cross-session play back. The app can fork a process, so each game gets its own PID. Or the engine can move its per-session VM state into a container it can reset in full.

## Removed quit paths

In May 2026 we disabled every UI path that triggers a mid-game quit. In August 2026 we removed the code behind them, because a disabled path is code no test covers and no user reaches. These went:

- **`AppState.returnToLibrary()`** and its `tearDownSessionState()` helper. The engine-terminated handler now owns the one teardown that runs.
- **`EngineSessionCoordinator.beginReturnToLibrary()`** and `armHangWatchdogIfNeeded()`. Nothing calls `mkxp_requestTerminate()` any more, so the `terminationExpected` flag went with them.
- **`EngineTerminationCoordinator`**, the whole class. It serialized an app-requested terminate against the next `selectGame`. With no app-requested terminate, and with `selectGame` refusing a second launch while a game is paused, the RGSS thread is always parked in `waitForGamePath` when `launchGamePath` runs.
- **In-game Quit toolbar button** - the row in `PlayerMoreSheet.swift`, its `onQuit` closure, and the "Return to Library" confirmation alert in `PlayerView.swift`.
- **Library "Quit and play" alert** - the "A game is paused" alert in `GameLibraryView.swift` is informational only.
- **Long-press context-menu Quit** - gone from `GameContextMenu.swift`.
- **Loading-hang escape** - `GameLoadingView.swift` shows a static "close Empo from the app switcher" label. The old escape button also armed a programmatic force-quit helper. We deleted that helper because App Store guideline 2.5.1 forbids apps that terminate themselves.
- **Error-alert OK while a game runs** - `RootView.swift` only dismisses the alert and tells the user to close the app from the app switcher.

To bring cross-session play back, rebuild these from this file and from the git history. The engine-side cleanup machinery (`pokemon_session_reset.rb`, the session-2+ paths in `binding-mri.cpp`) stays in place but never triggers.

## What still happens at engine shutdown

The user cannot switch to another game in the same process. The engine still does session teardown when Ruby raises `SystemExit` / `Reset`:

1. `binding-mri.cpp` catches the exception and calls `mkxp_setEngineExitedCleanly()`.
2. `runSessions` waits for `rqTermAck`, then `eventThread.cleanup()`, framebuffer clear, "Game session ended."
3. `mkxp_setEngineTerminated()` fires the iOS callback.
4. `AppState`'s callback sets `errorMessage = cleanExitMessage`. The SwiftUI alert appears.
5. The user taps OK. The alert dismisses, but `phase` stays non-nil, so SwiftUI does not navigate.
6. The user force-closes the app from the app switcher.
7. On the next launch, `CrashTracker.consumeRecovery()` deletes the on-disk `.session-active` markers. This fix landed with the alert UX. Without it, the marker outlived the in-memory flag and re-triggered "didn't exit cleanly" on every launch.

## Quit-bypass shims

Two `scripts/preload/platform_compat.rb` shims keep this flow safe when game scripts try to skip the engine's catch:

- **`Kernel.exit!` / `Process.exit!` redirect to `Kernel.exit`** - Pokemon Essentials' `pbExit` and many forks of it call `exit!` to skip `at_exit` handlers. On desktop, this is harmless. On iOS, `exit!` calls C `_exit(status)` directly, and the app vanishes before the engine knows. The redirect to `exit` raises `SystemExit` instead, which the engine catches. App Store guideline 2.5.1 also forbids programmatic process termination, so the redirect gives correct behavior and meets the policy.
- **`Thread.critical` / `Thread.critical=` no-ops on Ruby 1.9+** - Vintage RGSS code wraps `Marshal.load` and save-file I/O in `Thread.critical = true` blocks. This is a Ruby 1.8 cooperative-scheduling idiom, and Ruby 1.9 removed both methods. Without the shim, Ruby 1.9+ raises `NoMethodError` mid-quit. The error escapes the script-eval loop, and `SharedState::finiInstance()` segfaults on iOS while it tears down graphics with a pending exception.

See `docs/multi-ruby.md` for the wider picture.

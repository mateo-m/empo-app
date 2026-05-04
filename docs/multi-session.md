# Multi-Session

## Status

Cross-session play is currently **disabled**. After a clean game exit, Empo shows an alert ("close from app switcher to play again") instead of returning to the library. The user must force-close + reopen to start a different game.

The original "drop to library, pick another game in the same process" UX is parked behind a feature flag pending reliable Ruby state cleanup. See [`QUIT_PATHS_DISABLED.md`](../QUIT_PATHS_DISABLED.md) in the project root for the longer story.

## Why this is hard

iOS apps can't kill themselves and respawn. Android emulators (JoiPlay) sidestep this entirely by calling `Process.killProcess()` after each game. iOS has to clean up the active Ruby VM's state manually between games:

- Game A defines `class Foo < Bar`. The class lives in the active Ruby's constant table.
- Game B runs in the same VM. It defines `class Foo < Baz`. Ruby raises `TypeError: superclass mismatch for class Foo`.
- The hierarchy of leaked classes / monkey-patches / aliases / disposed RGSS objects across two arbitrary games' scripts is unpredictable.

A previous iteration shipped aggressive cross-session cleanup (constant-baseline diffing, singleton-method baseline, `MkxpNullMouse` shim for orphan globals, intrusive-list detachment for disposables, etc.) and it worked for Pokemon Z ↔ Pokemon Uranium. It didn't survive contact with broader game corpora - especially mixed-version sessions where the active Ruby's data structures differ between games.

The decision: rather than ship a half-working cross-session UX that breaks unpredictably, we surface a clean alert that asks the user to force-close. Future work could re-enable cross-session play either via process forking (separate PID per game) or by moving the engine's per-session VM state into a fully resettable container.

## What still happens at engine shutdown

Even though the user can't switch to another game in the same process, the engine still does session teardown when Ruby raises `SystemExit` / `Reset`:

1. `binding-mri.cpp` catches the exception, calls `mkxp_setEngineExitedCleanly()`.
2. `runSessions` waits for `rqTermAck`, then `eventThread.cleanup()`, framebuffer clear, "Game session ended."
3. `mkxp_setEngineTerminated()` fires the iOS callback.
4. `AppState`'s callback sets `errorMessage = cleanExitMessage`, the SwiftUI alert appears.
5. User taps OK → alert dismissed but `phase` stays non-nil so SwiftUI doesn't try to navigate.
6. User force-closes from app switcher.
7. On next launch, `CrashTracker.consumeRecovery()` deletes the on-disk `.session-active` markers (a fix that landed alongside the alert UX - without it, the marker outlived the in-memory flag and re-triggered "didn't exit cleanly" on every launch).

## Quit-bypass shims

Two `scripts/preload/platform_compat.rb` shims keep this flow working when game scripts try to skip the engine's catch:

- **`Kernel.exit!` / `Process.exit!` redirect to `Kernel.exit`** - Pokemon Essentials' `pbExit` (and forks like Vanguard) calls `exit!` to skip `at_exit` handlers. On desktop that's harmless; on iOS `exit!` calls C `_exit(status)` directly and the app vanishes before the engine knows. Redirecting to `exit` raises `SystemExit` instead, which the engine catches.
- **`Thread.critical` / `Thread.critical=` no-ops on Ruby 1.9+** - Vintage RGSS code wraps `Marshal.load` and save-file I/O in `Thread.critical = true` blocks (a Ruby 1.8 cooperative-scheduling idiom; both methods removed in 1.9). Without the shim, Ruby 1.9+ raises `NoMethodError` mid-quit, the error escapes the script-eval loop, and `SharedState::finiInstance()` segfaults on iOS while tearing down graphics with a pending exception.

See `docs/multi-ruby.md` for the broader picture.

# Multi-session

## Status

Cross-session play is **enabled** (feature flag: `CrossSessionPlay.enabled`
in `ios/Empo/src/App/CrossSessionPlay.swift`). After a clean game exit — the
game's own "Exit to desktop" menu, a `Reset`, or the in-game Quit — Empo
returns to the library and the user starts another game (or the same one) in
the same process. See `docs/session-switching-plan.md` for the full design
and its phased rollout.

## How it works

An iOS app cannot kill itself and start again (App Store guideline 2.5.1),
and CRuby cannot be re-initialized against used VM globals — `ruby_init`
assumes every interpreter global is in its untouched load-time state, and
`ruby_cleanup` does not put them back. A previous iteration tried to *clean*
the used VM between games (constant-baseline diffing, singleton-method
scrubbing, disposable detachment); the surface proved unbounded and it was
reverted.

The current architecture never reuses a dirty VM. Every session gets a
**factory-fresh Ruby VM instance**:

1. **Session loop** — `main.cpp` runs `init() → runSession() → park in
   mkxp_waitForGamePath() → runSession() → …`. Window, EGL/ANGLE context,
   and the OpenAL device/context persist; `SharedState`, `EventThread`, and
   the RGSS thread are per-session. `mkxp_setGamePath()` resets all
   per-session bridge state before publishing the next path.
2. **Instance manager** — `mkxp-z-apple-mobile/src/ruby_instance.cpp`. Each
   Ruby version's symbol-islanded interpreter (see `docs/multi-ruby.md`)
   ships as a standalone dylib (`RubyIsland<NN>.framework`, built by the
   `mkxp<NN>-island` targets in `ios/Dependencies/common.make`). Per session
   the RGSS thread acquires a fresh image of the right island:
   - **dlclose/dlopen**: unloading and reloading the image hands back
     pristine globals. Unload is verified per retire with an RTLD_NOLOAD
     canary, never assumed.
   - **copy-and-load**: when dyld refuses to unload, the next session
     dlopens a byte-identical copy at a unique tmp path (unlinked right
     after load). Distinct path → distinct image → fresh globals. The
     retired image's memory stays resident; see Memory below.
   - **static fallback**: builds that still link `mkxp<NN>-merged.o`
     directly get one session per version per process; the capability API
     reports DIRTY afterwards and the host shows the restart alert.
3. **Quiescence** — at session end `binding-mri.cpp` clears the pending
   exception and runs `ruby_cleanup`: VM threads stop (the island must have
   no live threads before dlclose), END/at_exit blocks and finalizers run,
   FDs close, and most of the GC heap returns. The RGSS thread then retires
   the instance, which also restores the pre-session sigaction table so
   Ruby's signal handlers never outlive their image.
4. **Launch gate** — the host asks `mkxp_sessionCapability(rubyVersion)`
   before starting a session (`CrossSessionPlay.launchBlocker`). FRESH
   launches; DIRTY/UNAVAILABLE shows an honest "close Empo from the app
   switcher" alert instead of a broken session.

Same-game restart is the same path — a restart is just a new session that
points at the same game directory, on a fresh instance.

## Memory

A retired instance that truly unloaded costs nothing. Under copy-and-load,
the retired image stays resident (minus what `ruby_cleanup` returned), and
iOS jetsams over-budget apps with no warning. While that mechanism is
active, `CrossSessionPlay.launchBlocker` also gates on
`os_proc_available_memory()` and degrades to the restart alert below a
headroom watermark — a temporary posture until the planned container reset
(plan Stage 3) makes retired sessions free and the watermark a
should-never-fire assertion.

## Quit paths

All re-enabled behind `CrossSessionPlay.enabled` (they were parked from May
2026 until cross-session play landed):

- **In-game Quit** — `PlayerMoreSheet.swift` (`quitEnabled`).
- **Library "Quit and play"** — the "A game is paused" alert in
  `GameLibraryView.swift`; quits the paused game and launches the tapped
  one once the termination coordinator sees the engine's ack.
- **Long-press context-menu Quit** — `GameContextMenu.swift`, paused games.
- **Clean-exit return** — `AppState.coordinatorEngineTerminatedUnexpectedly`
  drops to the library directly; a boot-gate parting message routes through
  the error alert whose OK calls `AppState.finishEndedSession()`.

Crashes keep the alert path: a crashed RGSS thread skips the retire path,
so its island stays checked out and `mkxp_sessionCapability` reports DIRTY.
A hung engine (no termination ack) remains terminal — the hang alert asks
for an app restart, as before.

## What happens at engine shutdown

1. `binding-mri.cpp` catches `SystemExit` / `Reset`, calls
   `mkxp_setEngineExitedCleanly()`, quiesces the VM (`ruby_cleanup`).
2. `runSession` waits for `rqTermAck`, joins the RGSS thread,
   `eventThread.cleanup()`, clears the framebuffer to black.
3. `mkxp_setEngineTerminated()` fires the iOS callback; the RGSS thread has
   already retired its Ruby instance.
4. The host either drops to the library (clean exit) or shows the relevant
   alert (crash / parting message). The engine parks in
   `mkxp_waitForGamePath()`.
5. The next `mkxp_setGamePath()` resets per-session bridge state and wakes
   the session loop.

## Quit-bypass shims

Two `scripts/preload/platform_compat.rb` shims keep this flow safe when game
scripts try to skip the engine's catch:

- **`Kernel.exit!` / `Process.exit!` redirect to `Kernel.exit`** - Pokemon
  Essentials' `pbExit` and many forks of it call `exit!` to skip `at_exit`
  handlers. On desktop, this is harmless. On iOS, `exit!` calls C
  `_exit(status)` directly, and the app vanishes before the engine knows.
  The redirect to `exit` raises `SystemExit` instead, which the engine
  catches. App Store guideline 2.5.1 also forbids programmatic process
  termination, so the redirect gives correct behavior and meets the policy.
  Note that with cross-session play, `at_exit` handlers now actually run
  (inside `ruby_cleanup` at session end) — the redirect keeps them from
  running at process-exit time instead.
- **`Thread.critical` / `Thread.critical=` no-ops on Ruby 1.9+** - Vintage
  RGSS code wraps `Marshal.load` and save-file I/O in
  `Thread.critical = true` blocks. This is a Ruby 1.8 cooperative-scheduling
  idiom, and Ruby 1.9 removed both methods. Without the shim, Ruby 1.9+
  raises `NoMethodError` mid-quit. The error escapes the script-eval loop,
  and `SharedState::finiInstance()` segfaults on iOS while it tears down
  graphics with a pending exception.

See `docs/multi-ruby.md` for the wider picture and
`docs/session-switching-plan.md` for the design rationale, rejected
alternatives, and the remaining phases (island dylib rollout, container
reset).

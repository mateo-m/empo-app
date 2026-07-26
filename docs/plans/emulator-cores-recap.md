# Recap: engine cores + RPG Maker MV/MZ support — implementation state

Companion to [`emulator-cores.md`](emulator-cores.md) (the design and decision log) and
[`emulator-cores-ui-inventory.md`](emulator-cores-ui-inventory.md) (the UI classification).
This records what was actually built, where, how it was verified, and what remains.

## What landed

### In this repository (branch `claude/rpg-maker-emulator-cores-8m2txt`)

- **The core contract** (`ios/Empo/src/Cores/`): `CoreKind` (forward-compatible Codable,
  mirroring `JgpRuntime`), `CoreCapabilities` (every field doc-commented with its UI
  consumer, or an explicit "nothing gates on it yet" note), `GameCore`, `SessionProviding`,
  `CoreSession`/`CoreSessionDelegate` (mirrors the engine-neutral half of
  `EngineSessionCoordinatorDelegate`), `CoreSurface`, `CoreRegistry`.
- **mkxp behind the contract** (`Cores/Mkxp/`): `MkxpCore` (honest capability declaration —
  quit/sequential `false`, everything else `true`) and `MkxpSession`, a mechanical wrapper
  over the existing coordinator machinery. mkxp launch/pause/input/termination bottoms out in
  the identical calls in identical order; deliberate direct mkxp couplings (crash markers,
  save migration, Ruby config, hang watchdog) are left in place and labeled.
- **`coreKind` metadata** with per-field-tolerant decoding, `*DetectedSchema` versioning, and
  lazy backfill (`resolvedCoreKind`: absent ⇒ `.mkxp`; unknown raw ⇒ graceful launch failure
  instead of feeding the Ruby VM).
- **MV/MZ detection + friendly rejection**: `RmWebDetection` in GameProbe (case-insensitive,
  requires the engine core JS, 10+ Linux-runnable tests) wired into `GameImportValidator` at
  probe time — folders, archives (selective-extraction markers), and JGPs all get "This is an
  RPG Maker MV/MZ game. Empo cannot play RPG Maker MV/MZ games yet, but support is planned."
  Every other invalid input keeps its pre-existing error; no MV/MZ game can import yet.
- **The dormant rmWeb session path**: `Cores/RmWeb/RmWebSession.swift`, registry entry,
  `CoreViewEmbedder`, `AppWindow` surface switch — all inside `#if canImport(RmWebHost)`, so
  the app builds identically until the submodule lands. AppState routes by `resolvedCoreKind`;
  quit-to-library and sequential-session behavior branch on capabilities (mkxp keeps the
  force-close alert).
- **Capability-driven UI**: Engine row in Game Info; core-gated Game Settings sections;
  capability-gated player menu (cheats/fast-forward/pause); registry-derived JGP supported
  list; core-neutral diagnostics copy. All gates pass for mkxp ⇒ identical render trees.
- **Docs**: `docs/core-authoring.md` (contributor guide, indexed), the plan + inventory +
  this recap.

### In the sibling repository `rmweb-core` (new, currently local at `/home/user/rmweb-core`)

Launcher-agnostic MV/MZ runtime; Empo is one optional adapter (`adapters/empo/`).

- **In-page TypeScript runtime** (bun-built IIFE, 32 unit tests, compile-time-typed bridge
  protocol in `protocol.ts` mirrored by the Swift host): save bridging (MV localStorage
  interception incl. `.bak` backups, byte-identical desktop `.rpgsave`s; MZ
  `StorageManager.saveZip/loadZip/remove` with a synchronous `exists` cache), Ogg Vorbis
  `decodeAudioData` fallback (input-detachment-safe; adapter tolerant of promise/sync/
  callback stbvorbis builds), DOM input injection with WebKit-accurate keyCode forcing,
  pause/resume via rAF gating and AudioContext suspension, terminate handshake that flushes
  saves, sync host channels (same-scheme sync XHR for reads, `prompt()` interception for
  writes).
- **Swift host** (`RmWebHost` + Linux-testable `RmWebCommon`): MV/MZ layout detection,
  case-insensitive path resolution with symlink refusal, custom-scheme serving with
  single-range 206 support and memory-mapped reads, save-name policy at the untrusted JS
  boundary, network blocking that fails closed (content rules incl. ws(s), navigation policy,
  and in-page constructor removal), content-process-death surfacing, snapshot API.

## Verification state

- **Runs here (Linux)**: runtime typecheck + 32 bun tests green; bundle built and synced into
  host resources; markdownlint green across both repos' tracked docs.
- **Cannot run here**: all Swift (no toolchain in this container). Every Swift file was
  written/reviewed by full-file inspection only. GameProbe and RmWebCommon tests are
  Linux-runnable in CI once pushed.
- **Adversarial review** (two independent passes, then fixes): empo-app — no compile
  blockers or mkxp regressions found; 8 minor findings, all fixed. rmweb-core — 1 blocker
  (ArrayBuffer detachment defeating the Vorbis fallback; fixed, with the fake upgraded to
  detach so the test proves it), plus save-contract, security (symlinks, WebSocket bypass,
  fail-open blocker), and media (Range requests) findings — all fixed.

## What a Mac developer does next (grep `TODO(rmweb-activation)`)

1. Build the branch; fix whatever trivia the first compile surfaces (expected, uncompiled).
2. Run swift-format/swiftlint (commits used `--no-verify`; hook tools absent here).
3. Push `rmweb-core` to its GitHub repo; add it as a submodule; apply the three commented
   XcodeGen entries in `ios/Empo/project.yml`; run `scripts/vendor-stbvorbis.sh` (verify the
   upstream API + Apache-2.0 attribution in the licenses UI).
4. Flip the phase-2 import gate to accept MV/MZ with `coreKind: .rmWeb`.
5. On-device: z-order/hit-testing for the webview surface, background pause routing,
   content-process-kill recovery UX, play-time session start for web games, `.rmmzsave`
   desktop-encoding verification against a real desktop save, AudioContext loop-point
   drift after long pauses, `.webm` movie playback reality check.

## Flagged decisions (changeable while unreleased)

- `rmweb-core` is GPL-2.0-or-later (ecosystem-consistent; permissive would maximize adapter
  adoption — owner's call).
- MZ on-disk save encoding follows the desktop-NW.js-UTF-8 hypothesis with a raw fallback;
  needs the on-device diff before compatibility is advertised.
- The mkxp adapter still lives in this repo (the model says core repos own their adapters;
  migrating it into mkxp-z-apple-mobile is future work).
- MVP shims report `Utils.isNwjs() === false`; the `fs-sync` facade exists behind an option
  for later plugin-compat work.

# Plan: engine cores and RPG Maker MV/MZ support

Status: **draft for review**. Nothing in this document is implemented yet. It exists to be
challenged before any code is written.

## Goal

Run games made with RPG Maker MV and MZ in Empo, and get there by introducing a first-class
concept of **cores**: pluggable engine runtimes behind one generic, capability-declaring API on
Empo's side. mkxp-z-apple-mobile becomes the first core. A new WKWebView-based runtime for MV/MZ
becomes the second. Future runtimes (Ren'Py, TyranoBuilder, HTML) become possible without
touching the launcher's spine again.

## Verdict up front: is MV/MZ support doable?

**Yes.** MV and MZ games are HTML5/JavaScript applications that ship wrapped in NW.js
(Chromium + Node.js) on desktop. On iOS the proven approach is a `WKWebView` hosting the game's
own `index.html`, plus a JavaScript shim that emulates the small slice of NW.js/Node the RPG
Maker runtime and popular plugins actually use. Several shipping iOS apps validate this exact
architecture — ArkRPG, RPG Pocket, RPGEmu, and notably RPGPlayer, which pairs mkxp-z for
XP/VX/VXAce with a web wrapper for MV/MZ: precisely the dual-core shape this plan proposes.

Two properties make this a good fit for Empo specifically:

- **WebKit is a system framework.** A second engine costs essentially zero binary size, unlike
  bundling another interpreter the way the three Rubys are bundled today.
- **`WKWebView` is out-of-process by design.** The web content process is separate from Empo's
  process, so the single-VM, single-session constraint that forces mkxp-z users to force-close
  the app does **not** apply. A web-core game can quit back to the library cleanly, and another
  game can start afterwards. This asymmetry is the founding use case for the capability API.

## Terminology (a deliberate challenge to the prompt)

The prompt calls these "emulator/interpreter cores" and describes mkxp-z as "an
emulator/interpreter for games made with RPG Maker XP". Neither runtime is an emulator in the
machine-emulation sense: mkxp-z is a **reimplementation of the RGSS runtime** (it runs the
game's Ruby scripts against rebuilt Graphics/Audio/Input APIs), and the MV/MZ runtime is a
**hosted browser environment** for the game's own JavaScript engine code. This matters for docs
and App Review vocabulary more than for code.

Proposal: keep the word **core** (it is short, and the libretro precedent makes it instantly
legible to contributors), but define it in docs as "an engine runtime adapter", not an emulator.

A second, more consequential correction: on iOS a core **cannot be a runtime-loadable plugin**.
The platform forbids loading executable code at runtime (the sole exception being JavaScript
inside WebKit). So "each core specifies its capabilities" is a **compile-time source contract**
— a Swift protocol plus a capabilities value — and third-party core authors contribute by
building Empo with their core linked in, exactly as mkxp-z-apple-mobile is linked in today.
There will never be a "download more cores" screen.

## Where Empo stands today

Findings from the current tree that shape the design:

- **No engine abstraction exists.** ~54 `mkxp_*` C bridge functions are called directly from
  ~21 Swift/ObjC files. `EngineSessionCoordinator` is the closest thing to a core driver, and
  its delegate protocol (`EngineSessionCoordinatorDelegate`) is already engine-neutral — a good
  seam.
- **`GameSession.LaunchInput`** is the closest thing to a launch descriptor; `MKXPSessionConfig`
  mixes generic fields (`userDataDirectory`, `networkEnabled`) with mkxp-only fields
  (`rubyVersion`, `syntaxTransformMode`, `joiplayCompat`, `postloadEnabled`).
- **One capability query already exists**: `GameImportValidator.checkRuntimeSupport` asks the
  engine `mkxp_getSupportedRGSSVersionMask()`. Precedent for "the runtime declares what it
  supports; the app asks".
- **A `CoreKind` seed already exists**: `JgpRuntime` (`Jgp.swift`) is a forward-compatible
  Codable enum of engine labels whose doc comment names MZ/MV as known-but-rejected runtimes.
  `GameImporter` rejects them today.
- **The single-session constraint is mkxp-specific.** `docs/multi-session.md` documents every
  neutralized quit path. All of that gating should become a capability check, not a hardcode.
- **`GameMetadata` has a stale comment referencing "the `coreKind` String pattern"** — the field
  was anticipated but never added. The per-field `try?` decoding and the `*DetectedSchema`
  versioning patterns in that file are the ones to copy.
- **The surface layer is SDL-specific.** `GameViewEmbedder`/`AppWindow` reparent SDL's UIKit
  view; a web core hosts a `WKWebView` instead. The view-hosting side needs its own seam.
- **Detection is well-factored already.** `ios/GameProbe` (Linux-testable SwiftPM package) owns
  "what does this game need"; `GameImportValidator.isLikelyGameRoot` / `validateResolvedGameRoot`
  own "is this a game". MV/MZ detection slots into both.

## Proposed architecture

### CoreKind

```swift
/// Persisted identity of the runtime a game is assigned to.
enum CoreKind: Codable {
    case mkxp          // RGSS 1/2/3 via mkxp-z-apple-mobile
    case rmWeb         // RPG Maker MV/MZ via WKWebView + NW.js shim
    case unsupported(raw: String)  // forward-compat, mirrors JgpRuntime
}
```

Stored in `Metadata/metadata.json` as `coreKind` + `coreKindDetectedSchema`, following the
existing per-field-tolerant decoding pattern. Detection happens at import (and lazily on first
launch for pre-existing libraries, so no migration pass is needed: absent field + successful
RGSS detection ⇒ `mkxp`).

### The core contract

Three protocols, one value type:

```swift
/// One per engine runtime. Stateless; a registry owns one instance per CoreKind.
protocol GameCore {
    var kind: CoreKind { get }
    /// Static capabilities, refined per game at resolve time (e.g. MV vs MZ,
    /// RGSS version mask, network policy).
    func capabilities(for game: ResolvedGame) -> CoreCapabilities
    func makeSession(launch: CoreLaunchDescriptor,
                     delegate: CoreSessionDelegate) throws -> CoreSession
}

/// One live game run. mkxp's implementation wraps today's EngineSessionCoordinator;
/// the web core's implementation owns a WKWebView.
protocol CoreSession: AnyObject {
    func start() async throws
    func pause() / resume()
    func requestTerminate()
    func injectInput(_ event: CoreInputEvent)
    var surface: CoreSurface { get }   // .sdlWindow(UIWindow) | .view(UIView)
}

/// Engine → app events. Today's EngineSessionCoordinatorDelegate, renamed and kept
/// engine-neutral: terminated(cleanly:), firstFrameRendered, gameRectChanged,
/// error/info dialogs, pause snapshot ready, text-input mode changed.
protocol CoreSessionDelegate: AnyObject { ... }
```

`CoreLaunchDescriptor` generalizes `GameSession.LaunchInput`: game dir, user-data dir, state
dir, settings, metadata, log path. Core-specific knobs (Ruby version, syntax transform; nw-shim
options) move into a per-core payload rather than living as optional fields on a shared struct.

### CoreCapabilities

The heart of the prompt's idea. Declarative, data-first, consumed by UI gating and the import
validator:

```swift
struct CoreCapabilities {
    /// Can a game end and return to the library without killing the process?
    let quitToLibrary: Bool
    /// Can another game start in the same process afterwards?
    let sequentialSessions: Bool
    /// Pause with frozen-frame snapshot (hero-zoom transitions, background pause).
    let pauseSnapshot: Bool
    let fastForward: Bool
    let cheats: Bool
    /// How touch controls deliver input: SDL scancodes vs. DOM key events.
    let inputInjection: InputInjectionKind
    let inGameKeyboardText: Bool
    let touchMouse: Bool
    /// Whether the core can enforce the per-game network toggle.
    let networkControl: NetworkControl   // .enforceable | .unavailable
    let modalDialogBridge: Bool
    let diagnostics: Set<DiagnosticField> // fps, renderer name, engine version…
}
```

Design rule: **a capability is what the core *can do or enforce*; a setting is what the user
*chooses per game*.** "Has network features" is not a capability of the core — `networkEnabled`
stays a per-game setting; the capability is whether the core can honor it. (This is a deliberate
push-back on the prompt's example.)

Design rule two: **no speculative capabilities.** Every field must have a consumer in the UI or
import pipeline and differ between the two real cores (or plausibly differ for the next one).
Grow the struct when a third core needs it, not before.

Immediate consumers of `quitToLibrary`/`sequentialSessions`: the in-game Quit button
(`PlayerMoreSheet.quitEnabled`), the library "A game is paused" alert, the long-press Quit
context action, the clean-exit "force-close Empo" alert — every site `docs/multi-session.md`
lists. mkxp declares `false/false` and nothing changes; rmWeb declares `true/true` and those
paths come back to life for web games only.

### Registry, detection, surfaces

- `CoreRegistry`: ordered list of built-in cores; maps `CoreKind` → `GameCore`, and exposes the
  per-core **detectors** the import validator consults. mkxp's detector wraps today's RGSS
  checks; rmWeb's detector recognizes `www/index.html` + `js/rpg_core.js` (MV) or `index.html` +
  `js/rmmz_core.js` (MZ) + `package.json`.
- Detection logic lives in `GameProbe` (Linux-testable), like `GameScriptProfile` today.
- Surface hosting: `GameViewEmbedder` grows a sibling; `RootView`/`AppWindow` switch on
  `CoreSurface`. SDL's window-reparenting dance stays isolated inside the mkxp core.

### What deliberately does *not* change

- The import pipeline's 8 invariants (`docs/import-pipeline.md`), container layout
  (`GameContainer`), settings storage, controls manifests (already core-agnostic up to the
  final key-injection step), pause UX, crash tracking, play-time logging.
- The mkxp core keeps its process-lifetime SDL/GL/OpenAL/Ruby state. The abstraction wraps it;
  it does not try to fix multi-session for mkxp.

## The rmWeb core (MV/MZ) — technical shape

What the second core needs, in dependency order:

1. **Serving game files.** A `WKURLSchemeHandler` (custom `empo-game://` scheme) rather than
   `loadFileURL`, for three reasons: no `file://` CORS pain, streamable responses for large
   assets, and — critically — **case-insensitive path resolution**. MV/MZ games authored on
   Windows routinely reference assets with mismatched case; iOS APFS is case-sensitive. The
   scheme handler resolves paths through a case-folding cache, the same problem mkxp's
   `pathCache` solves.
2. **NW.js shim.** A `WKUserScript` injected at document start providing the slice of
   `require('fs')`, `require('path')`, `process`, and `nw` that `rpg_core.js`/`rmmz_core.js`
   and common plugins touch. Decision needed (open question 6): report `Utils.isNwjs() ===
   true` and emulate the fs-based code paths, or report `false` and ride the engines' built-in
   browser fallbacks. Async fs bridges via `WKScriptMessageHandler`; the rare-but-real
   `fs.readFileSync` calls in plugins need a synchronous bridge (sync XHR against the scheme
   handler, or the classic synchronous `prompt()` interception) — flagged as the shim's riskiest
   corner.
3. **Saves.** Route `StorageManager` writes to `<container>/UserData/` through the native
   bridge, instead of letting them sink into WKWebView's opaque website-data store. This keeps
   saves inside the existing container contract (migration, deletion, future export/backup) and
   survives webview data-store eviction. MZ's promise-based `StorageManager` makes this clean;
   MV's sync localStorage path needs a write-through cache.
4. **Audio: the OGG problem.** WebKit's `decodeAudioData` does not decode Ogg Vorbis, and
   desktop-targeted MV/MZ games ship `.ogg` only (MV's `.m4a` fallbacks are only present when
   the developer exported for mobile). Proposal: runtime decode via a small Vorbis WASM/JS
   decoder (e.g. stbvorbis) patched into `WebAudio`/`AudioManager`, rather than transcoding at
   import. Runtime decode keeps imports fast and byte-identical, and transparently composes
   with encrypted audio (`.rpgmvo`/`.ogg_`), which the engine decrypts in-memory before
   decoding.
5. **Encrypted assets** (`.rpgmvp`/`.rpgmvo`/`.png_`/`.ogg_`): no work needed — the engines
   decrypt in JS with the key from `System.json`, as they do in browser deployments.
6. **Lifecycle.** Terminate = tear down the webview (clean, repeatable → the capability
   asymmetry). Pause = suspend the AudioContext + freeze the rAF loop via the shim; snapshot
   via `WKWebView.takeSnapshot` feeds the existing hero-zoom/pause-card UX. Handle
   `webViewWebContentProcessDidTerminate` (memory-pressure kills of the content process are the
   known failure mode of long web-game sessions) with a reload-to-title recovery path.
7. **Input.** Touch controls dispatch DOM `KeyboardEvent`s (MV/MZ `Input` class listens on
   `keydown`/`keyup`) instead of SDL scancodes; the existing controls-manifest layer stays,
   only the last-mile injection differs per `inputInjection` capability.

Known limitations to document rather than solve in the MVP: `.webm` movie playback (WebKit
support is codec-dependent; verify on-device), exotic plugins reaching deep into Node
(`child_process`, native modules — permanently out of scope), multi-window plugins.

## Phasing

Each phase lands independently shippable; mkxp behavior is bit-identical through phase 2.

1. **Core abstraction refactor.** Introduce `CoreKind`, `GameCore`/`CoreSession`/delegate,
   `CoreCapabilities`, `CoreRegistry`. Move `EngineSessionCoordinator` + `GameSession` behind
   the mkxp core. Add `coreKind` to metadata with lazy backfill. Capability-gate the
   multi-session UI sites (all still `false` for mkxp ⇒ zero visible change).
2. **Detection + import.** rmWeb detector in GameProbe; validator accepts MV/MZ roots; imports
   land with `coreKind = rmWeb`. Until phase 3 ships, MV/MZ imports are either rejected with a
   friendlier "not supported yet" or accepted-but-unlaunchable behind a flag (open question).
3. **rmWeb core MVP.** Scheme handler, shim, saves bridge, OGG decode, touch input. Target: a
   vanilla, unencrypted MV game and a vanilla MZ game run start-to-save.
4. **Capability-driven UX.** Quit-to-library + sequential sessions for web games; per-core
   toolbar (hide fast-forward/cheats where undeclared); JGP MV/MZ acceptance.
5. **Contributor docs.** `docs/core-authoring.md`: the contract, the capability semantics, a
   checklist, and how the two built-in cores implement it.

## Risks

- **Shim compatibility long tail.** Plugin ecosystems (Yanfly, VisuStella, MOG…) touch NW.js
  unevenly; "runs vanilla games" and "runs the popular modded games" are different milestones.
  Mitigation: capability-report issues per game, same as today's compatibility reports.
- **Web content process memory.** Large games can get the content process jetsammed;
  recovery UX required (see lifecycle above).
- **Refactor blast radius.** Phase 1 touches the hottest files in the app (`AppState`,
  `RootView`, coordinator). Mitigation: mechanical extraction with no behavior change, gated by
  the existing manual smoke flows; GameProbe changes covered by its Linux tests.
- **Sync-fs bridge fragility.** Documented as the shim's sharpest edge; a fallback is to
  preload small `data/*.json` synchronously into the shim's cache at boot, which covers the
  dominant `readFileSync` use.

## Open questions (to be answered before implementation)

1. **Branch scope.** Phase 1 only? Phases 1–2? Or drive toward the phase-3 MVP on this branch?
2. **Where does the rmWeb core live** — `ios/Empo/src/Cores/RmWeb/` in-repo, or a separate
   repo/submodule like mkxp-z-apple-mobile? (The shim JS assets need a tested home either way.)
3. **Naming.** `core` / `CoreKind` / `rmWeb` — happy? Alternative: `runtime`.
4. **Saves**: native-bridged into `UserData/` (recommended) vs. browser storage.
5. **Audio**: runtime Vorbis decode (recommended) vs. import-time transcode.
6. **`Utils.isNwjs()`**: `true` (bigger shim, better plugin compat) vs. `false` (lean on
   browser fallbacks, smaller surface). Recommendation: start `false` for the MVP, measure.
7. **Capability granularity**: is `capabilities(for game:)` (per-game refinement) the right
   call, or should capabilities be static per core?
8. **Mixed-session UX**: after a web game quits to the library, an mkxp game is technically
   launchable (first mkxp session of the process). Allow it, or keep sessions
   homogeneous-per-launch for predictability?
9. **Phase-2 import posture** for MV/MZ before the core ships: reject with "coming soon" vs.
   import-but-unlaunchable.
10. **This document's fate**: keep (indexed in `docs/README.md`) as a living design doc, or
    delete once `core-authoring.md` supersedes it?

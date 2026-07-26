# Plan: engine cores and RPG Maker MV/MZ support

Status: **v2 — decisions recorded, implementation authorized.** v1 of this document was a draft
for review; the open questions below have been answered by the project owner and are now
decisions.

## Goal

Run games made with RPG Maker MV and MZ in Empo, and get there by introducing a first-class
concept of **cores**: pluggable engine runtimes behind one generic, capability-declaring API on
Empo's side. mkxp-z-apple-mobile becomes the first core. A new WKWebView-based runtime for MV/MZ
becomes the second. Future runtimes (Ren'Py, TyranoBuilder, HTML) become possible without
touching the launcher's spine again.

Two structural requirements (owner decision):

- **Cores live in their own repositories and are launcher-agnostic.** A core repo must be
  usable by any iOS app without adopting Empo's API. Each core repo *may* ship an optional
  Empo adapter — a thin folder of sources conforming the core to Empo's core contract — but
  the core itself never imports Empo concepts.
- **Empo's side is one generic contract** (protocols + a capabilities value) that every
  adapter implements. Capability differences (e.g. "can quit without killing the app") drive
  UI gating instead of hardcodes.

## Verdict: is MV/MZ support doable?

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

### Researched dead end: vendoring NW.js itself

Can Empo run games' bundled NW.js instead of shimming it? **No.** NW.js is Chromium + Node.js
fused at the event-loop level; there is no iOS port and the NW.js team has stated mobile
support is not achievable (Apple requires the system WebKit engine for App Store-style
distribution, and NW.js's multi-process Chromium architecture does not map onto iOS process
rules). The community answers to every "NW.js on iOS?" request over a decade are consistent:
impossible; the closest cousin (nodejs-mobile) ports only the Node half, which is the half RPG
Maker games barely use. The WKWebView + shim approach is not a compromise pick — it is the only
viable architecture, and it is the one every shipping MV/MZ player on iOS uses.

### Researched dead end: distributing cores as downloadable binaries

Owner asked: can users download a compiled core and drop it in a folder, like Delta? Research
says no, and Delta itself does not work that way:

- **Delta**: each Delta core lives in its own repo and is added to the app as a **git
  submodule, compiled into the app** as a framework. Modularity is source-level, not
  drop-a-binary. (This is exactly the model this plan adopts.)
- **RetroArch on iOS**: cores are dylibs, but since iOS 10 they load **only from inside the
  signed app bundle** — a dylib dropped into Documents fails code-sign checks and `dlopen`
  refuses it. The App Store build ships only pre-approved cores; sideload builds bundle the
  cores at signing time.
- General rule: iOS forbids loading executable code that wasn't signed with the app. The sole
  exception is JavaScript inside WebKit — which, notably, means the *web core's runtime shim*
  is the one component that could be updated without an app update, but native cores cannot be.

So cores are a **compile-time source contract**: a contributor adds a core by adding its repo
as a submodule plus its Empo adapter to the build, exactly as mkxp-z-apple-mobile is built in
today. There will never be a "download more cores" screen.

### Researched decision: libretro — take inspiration, do not adopt the ABI

Owner suggested implementing the libretro API outright, since it is battle-tested. Assessment
after research: **not viable for either of our two cores; adopt its ideas, not its ABI.**

- The libretro contract inverts control: the frontend owns the loop and calls the core's
  `retro_run()` once per frame; the core renders into a frontend-provided framebuffer/GL
  context and pushes audio through frontend callbacks. Both our runtimes own their *own* loops
  and surfaces: mkxp-z runs a persistent SDL/GL/OpenAL/Ruby thread that owns a `UIWindow`
  (re-architecting it into a passive per-frame callback is a rewrite of the engine; nobody has
  ever produced an mkxp libretro core), and a `WKWebView` cannot exist inside a dylib at all —
  it is an out-of-process system view whose pixels and event loop Apple owns. There is no
  libretro path to WKWebView, and without WKWebView there is no MV/MZ on iOS.
- libretro also cannot express the things Empo actually needs from the contract: UIKit view
  embedding, per-game touch-control overlays, pause snapshots for SwiftUI transitions, and
  asymmetric "can this core quit without killing the process" semantics (in libretro, core
  unload is universal by design — the one capability we know differs).

What we *do* borrow from libretro: a small stable versioned contract; a per-core static
**info/manifest** describing identity and capabilities (libretro's `.info` files); negotiated
optional features rather than assumed ones; and the frontend/core vocabulary split (Empo =
frontend/launcher, core = runtime, adapter = glue).

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
- **The Info sheet, Settings sheet, and long-press context menu are XP-tailored.** A
  classification pass (global vs core-specific vs generalizable) is part of this effort; its
  inventory drives the phase-4 UI work.

## Repository architecture (owner decision)

```text
mateo-m/empo-app                  The launcher. Owns the core contract (protocols +
                                  capabilities), the registry, all UI, import pipeline.
                                  Contains the mkxp *adapter* (pre-existing Swift layer,
                                  refactored behind the contract in place).

mateo-m/mkxp-z-apple-mobile       Existing core repo (C++ engine, prebuilt static libs).
                                  Unchanged by this effort. Its Empo adapter stays in
                                  empo-app for now; migrating it into the engine repo to
                                  match the model below is future work.

mateo-m/rmweb-core (new)          The MV/MZ core repo. Launcher-agnostic. Layout:
  runtime/                        JS: NW.js shim, save bridge, input bridge, Vorbis decode
                                  glue, boot script. Tested with bun on any OS.
  host-apple/                     SwiftPM package "RmWebHost": WKWebView host, scheme
                                  handler, message bridges, a host-delegate protocol.
                                  Any iOS app can embed this without knowing about Empo.
  adapters/empo/                  Optional. Swift sources conforming RmWebHost to Empo's
                                  core contract. Compiled by Empo's Xcode project when the
                                  repo is checked out as a submodule. Other launchers
                                  ignore this folder and write their own adapter.
  docs/                           Core docs: shim surface, host API, save format.
```

Empo consumes `rmweb-core` as a git submodule (the mkxp-z-apple-mobile precedent), with
XcodeGen source paths for `adapters/empo/` and a package reference for `host-apple/`. The
adapter compiles inside the app target, so it can conform to Empo's protocols without any
circular package dependency, and the core repo never depends on Empo.

## Proposed architecture (Empo side)

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

Declarative, data-first, consumed by UI gating and the import validator:

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

Design rule (owner-confirmed): **a capability is what the core *can do or enforce*; a setting
is what the user *chooses per game*.** "Has network features" is not a capability of the core —
`networkEnabled` stays a per-game setting; the capability is whether the core can honor it.

Design rule two: **no speculative capabilities.** Every field must have a consumer in the UI or
import pipeline and differ between the two real cores (or plausibly differ for the next one).
Grow the struct when a third core needs it, not before.

Immediate consumers of `quitToLibrary`/`sequentialSessions`: the in-game Quit button
(`PlayerMoreSheet.quitEnabled`), the library "A game is paused" alert, the long-press Quit
context action, the clean-exit "force-close Empo" alert — every site `docs/multi-session.md`
lists. mkxp declares `false/false` and nothing changes; rmWeb declares `true/true` and those
paths come back to life for web games only.

### Settings, Info, and context-menu split (owner-requested)

The current per-game surfaces assume XP/mkxp. The refactor classifies every item three ways:

- **Global**: meaningful for any core (title/artwork, play time, saves location, network
  toggle, vertical alignment, controls layout…). Stays in shared UI, backed by `GameSettings`.
- **Core-specific**: meaningful only for one core (Ruby version override, syntax transform,
  postload scripts, joiplayCompat, mkxp.json overlay fields; later: nw-shim options). Moves
  into a per-core settings *section* the adapter contributes, shown only for that core's
  games.
- **Generalizable**: same user intent, different per-core mechanism (fast-forward, cheats,
  in-game keyboard, touch-mouse). Stays global in UI but renders/enables per the core's
  declared capability.

A full item-by-item inventory of the Info sheet, Settings sheet, context menu, player toolbar,
and app settings feeds the phase-4 work (kept as an appendix once compiled).

### Registry, detection, surfaces

- `CoreRegistry`: ordered list of built-in cores; maps `CoreKind` → `GameCore`, and exposes the
  per-core **detectors** the import validator consults. mkxp's detector wraps today's RGSS
  checks; rmWeb's detector recognizes `www/index.html` + `js/rpg_core.js` (MV) or `index.html` +
  `js/rmmz_core.js` (MZ) + `package.json`.
- Detection logic lives in `GameProbe` (Linux-testable), like `GameScriptProfile` today.
- Surface hosting: `GameViewEmbedder` grows a sibling; `RootView`/`AppWindow` switch on
  `CoreSurface`. SDL's window-reparenting dance stays isolated inside the mkxp adapter.

### What deliberately does *not* change

- The import pipeline's 8 invariants (`docs/import-pipeline.md`), container layout
  (`GameContainer`), settings storage, controls manifests (already core-agnostic up to the
  final key-injection step), pause UX, crash tracking, play-time logging.
- The mkxp core keeps its process-lifetime SDL/GL/OpenAL/Ruby state. The abstraction wraps it;
  it does not try to fix multi-session for mkxp.
- mkxp-z-apple-mobile (the engine repo) is untouched.

## The rmWeb core (MV/MZ) — technical shape

What the second core needs, in dependency order:

1. **Serving game files.** A `WKURLSchemeHandler` (custom `empo-game://`-style scheme; the
   host names the scheme) rather than `loadFileURL`, for three reasons: no `file://` CORS
   pain, streamable responses for large assets, and — critically — **case-insensitive path
   resolution**. MV/MZ games authored on Windows routinely reference assets with mismatched
   case; iOS APFS is case-sensitive. The scheme handler resolves paths through a case-folding
   cache, the same problem mkxp's `pathCache` solves.
2. **NW.js shim.** A `WKUserScript` injected at document start providing the slice of
   `require('fs')`, `require('path')`, `process`, and `nw` that `rpg_core.js`/`rmmz_core.js`
   and common plugins touch. Decision: the MVP reports `Utils.isNwjs() === false` (lean on the
   engines' browser fallbacks, shim `StorageManager` directly) and revisits once vanilla games
   run. Async fs bridges via `WKScriptMessageHandler`; the rare-but-real `fs.readFileSync`
   calls in plugins need a synchronous bridge (sync XHR against the scheme handler, or
   synchronous `prompt()` interception) — flagged as the shim's riskiest corner.
3. **Saves (owner decision).** Route `StorageManager` writes to the host-provided save
   directory (for Empo: `<container>/UserData/`) through the native bridge, instead of letting
   them sink into WKWebView's opaque website-data store. This keeps saves inside the existing
   container contract (migration, deletion, future export/backup) and survives webview
   data-store eviction. MZ's promise-based `StorageManager` makes this clean; MV's sync
   localStorage path needs a write-through cache.
4. **Audio (owner decision).** WebKit's `decodeAudioData` does not decode Ogg Vorbis, and
   desktop-targeted MV/MZ games ship `.ogg` only. Runtime decode via a small Vorbis WASM/JS
   decoder (e.g. stbvorbis) patched into `WebAudio`/`AudioManager`. Imports stay fast and
   byte-identical, and decoding composes transparently with encrypted audio
   (`.rpgmvo`/`.ogg_`), which the engine decrypts in-memory before decoding.
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

All phases are in scope (owner decision). Each lands independently shippable; mkxp behavior is
bit-identical through phase 2.

1. **Core abstraction refactor** (empo-app). Introduce `CoreKind`, `GameCore`/`CoreSession`/
   delegate, `CoreCapabilities`, `CoreRegistry`. Move `EngineSessionCoordinator` +
   `GameSession` behind the mkxp adapter. Add `coreKind` to metadata with lazy backfill.
   Capability-gate the multi-session UI sites (all still `false` for mkxp ⇒ zero visible
   change).
2. **Detection + import** (empo-app). rmWeb detector in GameProbe; the validator recognizes
   MV/MZ roots and rejects them with a specific "RPG Maker MV/MZ isn't supported yet" message
   — shown **only** for actual MV/MZ imports; every other invalid input keeps today's errors.
   The detector and message flip to acceptance when the core ships.
3. **rmWeb core MVP** (rmweb-core repo). Scheme handler, shim, saves bridge, OGG decode,
   DOM input, lifecycle. Target: a vanilla MV game and a vanilla MZ game run start-to-save
   under any host embedding `RmWebHost`.
4. **Capability-driven UX** (empo-app + adapter). Quit-to-library + sequential sessions for
   web games; **mixed sessions allowed** (owner decision: after web games quit cleanly, an
   mkxp game may start — it simply becomes the session's last game, since only the mkxp core
   lacks quit); per-core Info/Settings/context-menu surfaces per the classification above;
   JGP MV/MZ acceptance.
5. **Contributor docs.** `docs/core-authoring.md`: the contract, capability semantics, the
   separate-repo + optional-adapter model, a checklist, and how the two built-in cores
   implement it.

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
- **No on-device verification during initial development.** The implementation lands
  compile-clean by inspection and Linux-testable where possible (GameProbe, runtime JS);
  first-build fixes on a Mac are an expected follow-up step.

## Decision log (2026-07-26, project owner)

1. **Scope**: all phases, ambitious.
2. **Core location**: separate launcher-agnostic repos; optional Empo adapter inside the core
   repo; any developer can use a core without Empo's API.
3. **Naming**: "core" confirmed. libretro: inspiration yes, ABI no (see research above).
   Downloadable cores: ruled out by platform (see research above).
4. **Capability vs setting split**: confirmed, including the Info/Settings/context-menu
   classification work.
5. **Saves**: native-bridged into the host-provided directory.
6. **Audio**: runtime WASM Vorbis decode.
7. **Mixed sessions**: allowed; expectation is that mkxp remains the only quit-incapable core.
8. **Import posture**: reject MV/MZ with a friendly, MV/MZ-specific "not supported yet".

# Authoring a core for Empo

Empo runs games through **cores**: engine runtime adapters behind one generic,
capability-declaring contract. mkxp-z (RPG Maker XP/VX/VX Ace) and rmweb-core (RPG Maker
MV/MZ) are the built-in cores. This guide is for contributors who want Empo to run another
engine's games — Ren'Py, TyranoBuilder, HTML packages, anything with an iOS-viable runtime.

Design background lives in [`plans/emulator-cores.md`](plans/emulator-cores.md); the
per-surface UI classification is in
[`plans/emulator-cores-ui-inventory.md`](plans/emulator-cores-ui-inventory.md).

## The model in one paragraph

A **core** is a launcher-agnostic runtime that lives in its own repository and knows nothing
about Empo. An **adapter** is a thin folder of Swift sources — conventionally
`adapters/empo/` inside the core's repo — that conforms the core to Empo's contract. Empo
consumes the core repo as a git submodule and compiles the adapter inside the app target, so
the adapter can reference Empo types without any circular dependency, and other launchers can
embed the same core with their own adapter (or none). On iOS a core can never be a
runtime-loadable plugin: code must be signed with the app, so integration is always at build
time. The only runtime-updatable component a core can have is JavaScript executed inside
WebKit.

## What you must build

### 1. The core itself (your repo, your rules)

Hard requirements Empo imposes are few:

- **Host-agnostic API.** No Empo imports, no Empo assumptions. rmweb-core's `RmWebHost`
  package is the reference: a controller the host instantiates per game session, a delegate
  protocol for events, a descriptor struct for inputs (game folder, save directory, options).
- **A session must be startable, pausable, terminable.** Termination must be safe to call at
  any time and must not lose player saves (flush before teardown; rmweb-core's
  terminate-handshake with a watchdog is the pattern).
- **Saves belong to the host.** Write them where the host says, in a documented — ideally
  desktop-compatible — format. Never squirrel state away in opaque storage the host cannot
  migrate, back up, or delete.
- **Be honest about failure.** Surface load failures and runtime deaths as events; never
  swallow them.

### 2. Engine detection (Empo's side, `ios/GameProbe`)

Empo must recognize your engine's games at import. Add a detector to the `GameProbe` SwiftPM
package (Linux-testable, no app dependencies) following `RmWebDetection.swift`: static
`detect(in:)` over the game folder, strict enough that unrelated folders are never claimed
(require an engine-identifying file, not just an `index.html`). Add tests mirroring
`RmWebDetectionTests`.

### 3. The adapter (`adapters/empo/` in your core repo)

Conform to the contract in `ios/Empo/src/Cores/`:

- **`GameCore`** — identity (`CoreKind`) plus `capabilities(for:metadata:)`.
- **`SessionProviding`** — creates a `CoreSession` for a launch.
- **`CoreSession`** — one live game run: `start()`, `requestPause()/requestResume()`,
  `requestTerminate()`, `injectInput(_:)`, `surface`.
- **`CoreSessionDelegate`** — events into the app: frame rendered, terminated (clean or
  not), game-rect changes, error/info dialogs, pause snapshot.

Then register the core in `CoreRegistry` (guarded by `#if canImport(YourHostModule)` so Empo
builds before the submodule lands) and add a `CoreKind` case.

### 4. Capabilities: declare only what is true

`CoreCapabilities` is consumed by UI gating — every field has a concrete consumer:

| Capability | What it gates |
| --- | --- |
| `quitToLibrary` | In-game Quit button, context-menu Quit |
| `sequentialSessions` | Whether ending a game frees the session for another, or shows the force-close alert |
| `pauseSnapshot` | Pause button + frozen-frame hero transitions |
| `fastForward` | Speed toggle in settings + player menu |
| `cheats` | Cheats row in the player menu |
| `inputInjection` | How touch controls deliver input (SDL scancodes vs DOM key events) |
| `inGameKeyboardText` | Keyboard toolbar button |
| `touchMouse` | "Touch acts as mouse" setting |
| `networkControl` | Whether the per-game network toggle is enforceable |
| `modalDialogBridge` | Native alert bridging for in-game message boxes |
| `diagnostics` | Which rows the debug overlay shows |

Two rules, enforced in review:

1. **A capability is what the core can do or enforce; a setting is what the user chooses per
   game.** Don't add "hasFeatureX the game might use" — add "core can enforce/provide X".
2. **No speculative capabilities.** A new field needs a consumer in the UI or import pipeline
   and a real difference between existing cores.

Declare `false` for anything your MVP does not actually implement. mkxp declares
`quitToLibrary: false` because its Ruby VM genuinely cannot be reset
([`multi-session.md`](multi-session.md)) — honest declarations are what let the UI promise
users only what works.

### Designated extension point: core requirements

Capabilities describe what a core **can do**. Some future cores will also have
**requirements** — prerequisites a game needs before it can run: user-supplied console keys
(3DS-class emulators), BIOS images, or shared runtime packages (the RGSS RTP alert is the
existing proto-example). Requirements are deliberately not modeled yet: neither built-in core
needs them, and the no-speculative-fields rule applies. When the first core with a
prerequisite lands, add a `CoreRequirements` type next to `CoreCapabilities` and give the
launcher the generic UX: an import slot, per-core (not per-game) storage, a validation hook,
and a launch-time gate with a specific message. Never bundle or download such material — key
and BIOS files must always be user-supplied imports, for the same legal reasons the RTP is.

### 5. Per-core UI surfaces

The Info sheet, Settings sheet, and import errors render per-core content. Follow the
inventory's classification: global rows stay shared; your engine-specific settings get their
own gated section (as the mkxp-only rows do); import rejection copy for recognized-but-
unsupported content must name the engine specifically.

## Checklist

- [ ] Core repo: host-agnostic API, session lifecycle, host-owned saves, documented formats.
- [ ] Detector + tests in `GameProbe` (never claims foreign folders).
- [ ] `CoreKind` case, adapter conforming `GameCore` + `SessionProviding` + `CoreSession`,
      registry entry behind `canImport`.
- [ ] Honest `CoreCapabilities` with doc comments citing consumers.
- [ ] Import validator wiring: recognized → import (or a specific "not supported yet").
- [ ] Submodule + XcodeGen entries (package reference, target dependency, adapter source
      path — see the commented template in `ios/Empo/project.yml`).
- [ ] License entries for your core's dependencies in the licenses UI.
- [ ] On-device smoke: import, play, save, pause/resume, quit (if capable), reimport.

## Reference implementations

- **mkxp** (`ios/Empo/src/Cores/Mkxp/`): wraps a process-lifetime, in-process C++ engine —
  the "everything is a singleton" worst case, still expressible through the contract.
- **rmweb** (`rmweb-core` repo + `ios/Empo/src/Cores/RmWeb/`): disposable out-of-process
  WKWebView sessions — the clean case, and the reason the capability API exists.

# Appendix: UI surface inventory — global vs core-specific

Companion to [`emulator-cores.md`](emulator-cores.md). Classification of every user-facing
surface currently tailored to RPG Maker XP / mkxp-z. Legend:

- **G** — global: applies to any core, stays in shared UI.
- **M** — mkxp-only: hide or move behind the mkxp adapter / a capability check.
- **GPC** — generalizable with a per-core mapping: same user intent, per-core mechanism or copy.

## 1. Game "Info" sheet (`GameInfoView.swift`)

| Item | Classification | Notes |
| --- | --- | --- |
| Banner image, artwork tile, editable title, customization hint | G | Artwork *fallback chain* (PE `.exe` icons, `Graphics/Titles`) is GPC — per-core artwork prospector. Original-title source (`Game.ini`) is GPC — MV/MZ title lives in `data/System.json` `gameTitle`. |
| Details: date added, last played, play time, size on disk, local ID | G | |
| Missing row: engine/core identity | GPC | Add "Engine" row from `coreKind` + detected variant ("RPG Maker XP (RGSS1)" / "RPG Maker MZ"). |
| Runtime section (debug-gated): RGSS version, Ruby (bundled), Ruby (runtime) | M | Generalize as an optional per-core `[DiagnosticRow]`; keep the `debugLogs` gate. |
| Actions: browse files, export logs, pickers | G | Log *content* is core-produced. |

## 2. Game "Settings" sheet (`GameSettingsView.swift`)

Backends: `GameSettings` (Empo per-game, `EmpoState/game_settings.json`) and the mkxp.json
overlay (`EngineMkxpSettings` / `EngineConfigProjector`). The provenance caption
("yours"/"game") and "Use game value" reset are overlay concepts (GPC — only for cores with a
developer-authored config file).

| Setting | Backing | Classification |
| --- | --- | --- |
| Fast forward + speed slider | `GameSettings.speedMultiplier` (runtime) | GPC → capability `fastForward` |
| Smooth scaling | overlay | GPC |
| Fixed aspect ratio | overlay | GPC |
| VSync | overlay | GPC (hide when unsupported) |
| Render scale | overlay (`enableHires`) | M as implemented; GPC concept (devicePixelRatio for web) |
| Font scale, solid fonts | overlay | M |
| Portrait position | `GameSettings.verticalAlignment` (runtime) | G intent; plumbing goes through `MKXPSessionConfig` — should move host-side |
| Frame skip | overlay | M |
| Postload scripts | `GameSettings` (restart) | M |
| Path cache | overlay | GPC (rmWeb scheme handler case-folds too) |
| In-game keyboard | `GameSettings` (runtime; PE-detection default) | M default logic; GPC capability `inGameKeyboardText` |
| Touch acts as mouse | `GameSettings` (runtime) | GPC → capability `touchMouse` |
| JoiPlay compatibility | `GameSettings` (restart) | M |
| Network access | `GameSettings` (restart) | G setting; enforcement is the `NetworkControl` capability |
| Ruby version picker | `GameSettings.rubyVersionOverride` (restart) | M |
| Compatibility mode picker | `GameSettings.useModernRuby` (restart) | M |
| Restart-required pill mechanics | `@Setting` flags + `EngineMkxpSettings` (all restart) | G mechanism; label map is per-core |
| Reset to defaults, toolbar | | G |
| "Can't read this game's mkxp.json" warning | overlay parse state | GPC copy ("engine config") |

## 3. Long-press context menu (`GameContextMenu.swift`)

All actions G (Cancel import, Play/Resume, Info, Settings, Select, Delete). The
commented-out Quit is the clearest `quitToLibrary` consumer.

## 4. Player toolbar + more sheet

| Item | Classification | Notes |
| --- | --- | --- |
| Toggle keyboard | GPC | `inGameKeyboardText`; mkxp uses `mkxp_pushTextInput`, rmWeb dispatches DOM input |
| Edit/show/hide controls, controller remap | G | Controls manifests already core-agnostic; last-mile injection differs |
| Cheats | M → capability `cheats` | mkxp injects `MKXP_SCANCODE_HOME` for JoiPlay-derived `Scene_Cheat` |
| Fast forward | GPC → `fastForward` | |
| Diagnostics overlay toggle | GPC → `diagnostics` | |
| Pause | G → `pauseSnapshot` | |
| Quit (hard-coded `quitEnabled = false`, `PlayerMoreSheet.swift:124`) | capability `quitToLibrary` | |
| `hasContent(...)` menu-visibility logic | GPC | Must consult capabilities or the Menu button renders empty |

## 5. App Settings (`SettingsView.swift`)

Look & Feel, About, build info: all G. Advanced section:

| Setting | Classification | Notes |
| --- | --- | --- |
| Diagnostics overlay | GPC | Description names "Ruby version" — copy must be generic/per-core |
| Show viewport bounds + color | M → GPC | Direct `mkxp_setShowViewportBounds`/`Color` calls incl. at `AppSettings.init`; rmWeb analogue is host-side overlay |
| Show touch zone | G | Host-side only |
| Clean up broken imports, debug logs toggle, max log files | G | Debug-log plumbing is GPC (rmWeb pipes WKWebView console) |

## 6. Everything else naming RPG Maker / RGSS / Ruby / mkxp

- **Diagnostics overlay** (`DebugOverlayView.swift`, 12 `mkxp_*` calls): title·RGSSn (GPC),
  Ruby version (M), compatibility mode (M), ANGLE/Metal renderer (GPC "renderer"), FPS (GPC),
  memory (G). Strongest argument for core-returned `[(label, value)]` diagnostics.
- **Library**: empty-state copy names RPG Maker (GPC); "Run-Time Package Required" alert (M —
  RTP has no MV/MZ analogue); "A game is paused" force-close alert (capability
  `sequentialSessions`); delete/invalid/cancel alerts (G).
- **Import errors** (`GameImportValidator.swift`): `.notAnRPGMakerGame` → "no core claimed
  this folder" (GPC); `.invalidScripts` (M); `checkRuntimeSupport` RGSS mask (M
  implementation, the capability-query precedent); root detection (M detector → per-core
  detectors in GameProbe).
- **JGP** (`Jgp.swift`, `GameImporter.swift`): `JgpRuntime` enum is the `CoreKind` seed (GPC);
  rejection message's supported-engine list must derive from the core registry (GPC);
  `JgpConfiguration` mapping and `mkxpZ → useModernRuby` forcing (M).
- **Controls**: `KeyCatalog` semantic labels G, `MKXP_SCANCODE_*` values M (`inputInjection`);
  `ControllerRemapCatalog` annotations GPC; `TouchControls.mm → mkxp_injectKeyEvent` M.
- **`ControlsLayout.swift:887` hardcodes "RPG Maker viewports are 4:3"** — MV is 816x624,
  MZ defaults 1280x720 (16:9). Real layout-bug risk; aspect must come from the core/game.
- **Lifecycle alerts** (`RootView.swift`, `GameLoadingView.swift`): engine-hung and
  force-close copy (M constraint → `sequentialSessions`); game `msgbox` info/error alerts
  (GPC → `modalDialogBridge`).
- **Licenses** (`LicensesView.swift`): mkxp-z/Ruby entries should be assembled per linked
  core (GPC).
- **Silent couplings**: `GameContainer` mkxp.json paths; `SaveMigration` reads
  `Game/mkxp.json` `windowTitle` (M); `PokemonEssentialsDetection` (M);
  `AppWindow`/`GameViewEmbedder` SDL hosting (M surface); GameProbe detectors (M, already
  isolated).

## Summary

- 82 `mkxp_*` call sites across 20 files; top: `EngineSessionCoordinator` (24),
  `DebugOverlayView` (12), `GameSession` (8), `PlayerView` (5), `RootView` (5).
- Hard-coded single-session constraint sites (become `quitToLibrary`/`sequentialSessions`):
  `PlayerMoreSheet.swift:124`, `GameContextMenu.swift:37-46`,
  `GameLibraryView.swift:1093-1113`, `RootView.swift:141-145`, `GameLoadingView.swift:204`.
- User-visible strings naming mkxp/RGSS/Ruby: `GameSettingsView.swift:338,472,488,502,513-539`;
  `GameInfoView.swift:166-198`; `SettingsView.swift:81`; `DebugOverlayView.swift:236-265`;
  `GameLibraryView.swift:377,1077`; `GameImportValidator.swift:24,30,755-760`;
  `GameImporter.swift:55-56`; `LicensesView.swift:164-166`.

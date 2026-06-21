# Empo — domain context

Shared vocabulary for the iOS host app, native engine submodule
(`mkxp-z-apple-mobile`), and dependency build tree (`ios/Dependencies`).

## Core nouns

**Game** — An imported RPG Maker / mkxp-z project the user can launch from
the library. Immutable script and asset tree under `<container>/Game/`.

**Container** — On-disk layout for one library entry:
`<Documents>/Games/<uuid>/` with `Game/`, `EmpoState/` (managed configs),
and `Metadata/` (sidecars, artwork). See `GameContainer.swift`.

**Session** — One engine run from `mkxp_setGamePath()` until the RGSS
thread exits. Empo currently allows **one session per process launch**;
see `docs/multi-session.md`.

**Engine** — The mkxp-z C++ runtime linked into the Empo binary: SDL +
ANGLE + OpenAL + per-Ruby merged binding objects. Lifecycle is owned by
`EngineHost` in `main.cpp` (init → runSession → shutdown).

**Script profile** — Host-side classification of a game's Ruby dispatch
and syntax-transform needs. `GameScriptProfile.analyze()` returns ruby
version (18 / 19 / 31) and whether scripts look modern. Persisted on
`GameMetadata` with schema `unified`.

**Catalog vs importer** — `GameCatalog` scans containers and builds
`GameEntry` read models. `GameImporter` seeds metadata and settings
after a successful import. `GameLibrary` orchestrates UI state and I/O.

**Patches (two kinds)** — (1) **Ruby source patches** applied at native
deps build time (`ios/Dependencies/ruby*.patches.lst`, syntax-transform in
the engine repo). (2) **Curated script patches** merged at launch into
`<container>/EmpoState/patches.json` for the engine `Patcher` (
`PatcherDistribution.swift`).

## Repository map

| Area | Role |
|------|------|
| `ios/Empo/src/` | SwiftUI host: library, player, settings |
| `mkxp-z-apple-mobile/` | Engine submodule: RGSS, bindings, syntax-transform |
| `ios/Dependencies/` | Native deps makefile, Ruby trees, patch manifests |
| `docs/` | Architecture docs, multi-ruby guide |

## Multi-Ruby (summary)

Three interpreters ship in one binary: Ruby 1.8, 1.9, 3.1. Each version's
libruby + mkxp binding merges into `mkxp{18,19,31}-merged.o`. The host sets
`mkxp_setActiveRubyVersion()` and `mkxp_applySessionConfig()` before boot.
Ruby 3.0 was dropped; games bundling `ruby300.dll` fold onto 3.1 + Legacy
syntax-transform. Details: `docs/multi-ruby.md`.

## Where to look first

| Task | Start here |
|------|------------|
| Import / library card | `GameLibrary`, `GameCatalog`, `GameImporter` |
| Launch wiring | `GameSession`, `AppState.selectGame` |
| Ruby version / modern scripts | `GameScriptProfile` |
| Engine per-game settings | `MKXPSessionConfig`, `app_bridge.h` |
| Native Ruby build | `ios/Dependencies/common.make`, `apply-ruby-patches.sh` |
| Session lifecycle | `main.cpp` `EngineHost`, `docs/multi-session.md` |

## Related documents

- `docs/multi-ruby.md` — dispatch, detection, syntax-transform

- `docs/multi-session.md` — why cross-session play is disabled

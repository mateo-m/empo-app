# Empo — domain context

Shared vocabulary for the Empo iOS host and mkxp-z engine submodule.
Use this file before architecture reviews or cross-repo refactors.

## Terms

| Term | Meaning |
|------|---------|
| **Game** | An imported RPG Maker project on disk inside a `GameContainer`. |
| **Container** | `Games/<uuid>/` layout: immutable `Game/` tree, `EmpoState/` managed config, `Metadata/` sidecars. |
| **Session** | One engine run from `mkxp_setGamePath` until `mkxp_setEngineTerminated`. Currently one session per app launch. |
| **Engine** | mkxp-z runtime (C++/Ruby): SDL, ANGLE, OpenAL, RGSS thread, script binding. |
| **ScriptProfile** | `GameScriptProfile.analyze()` — single directory walk for Ruby version + modern-script detection. |
| **Host** | Empo SwiftUI app: library UI, import pipeline, bridge configuration. |

## Repository map

```text
empo/                          iOS host app, deps build, docs
  ios/Empo/                    SwiftUI + Xcode project (xcodegen)
  ios/Dependencies/            Native Ruby/SDL/OpenSSL build (common.make)
  mkxp-z-apple-mobile/         Engine submodule (binding, main, patches)
```

## Patch ownership

| Layer | Location | Applied by |
|-------|----------|------------|
| Ruby iOS port | `ios/Dependencies/ruby{18,19,31}/*.patch` | `apply-ruby-patches.sh` + manifest |
| Syntax-transform | `mkxp-z-apple-mobile/syntax-transform/3.1/*.patch` | Listed in `ruby31.patches.lst` |
| Engine preload | `mkxp-z-apple-mobile/scripts/preload/*.rb` | Runtime, not build-time |

## Related docs

- `docs/multi-ruby.md` — dispatch, detection, syntax-transform
- `docs/multi-session.md` — why cross-session play is disabled

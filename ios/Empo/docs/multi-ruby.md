---
title: Multi-Ruby
description: The RPG Maker XP, VX and VX Ace core holds three Ruby interpreters. How Empo detects the version that a game needs, and how the engine dispatches to it.
---

## Overview

The RPG Maker XP, VX and VX Ace core (`MkxpCore.framework`) holds three Ruby interpreters: 1.8.8, 1.9.3, and 3.1.3. At launch, it dispatches each game to the correct one. A vintage RPG Maker XP game runs on Ruby 1.8's actual parser and VM. A modern Pokemon Essentials fork built on the mkxp-z runtime routes to Ruby 3.1. Empo applies the syntax-transform compatibility mode for the legacy game-script idioms that PE uses. Modern forks that ship `x64-msvcrt-ruby300.dll` fold onto the same 3.1 dispatch. The syntax-transform parser patches exist only in the 3.1 source, so the RPG Maker XP, VX and VX Ace core has no 3.0 build.

The four PSDK cores have Ruby 2.5, 3.0, 3.2 and 3.3 for PSDK games, one in each core. This page does not cover them. See [`cores.md`](cores.md).

## Why

Different RPG Maker generations target different Ruby versions:

| Generation               | Engine DLL                       | Ruby version | Typical games                                                                                                           |
| ------------------------ | -------------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------- |
| RGSS1 (RPG Maker XP)     | `RGSS104E.dll`                   | 1.8          | Vintage Pokemon Essentials forks                                                                                        |
| RGSS2 (RPG Maker VX)     | `RGSS200J.dll`                   | 1.8          | A handful of community projects                                                                                         |
| RGSS3 (RPG Maker VX Ace) | `RGSS300.dll`                    | 1.9          | Traditional VX Ace games                                                                                                |
| mkxp-z modern            | bundled `x64-msvcrt-rubyXYZ.dll` | 3.1          | Modern Pokemon Essentials forks that ship the mkxp-z runtime. Bundles for 3.0 fold onto 3.1 + Legacy compatibility |

A single Ruby version that tries to cover all of these is fragile. Ruby 1.8 cannot parse modern code (keyword args, safe nav, pattern matching). Ruby 3.x cannot parse a lot of vintage code (`when X:`, character literal arithmetic, removed `Object#id`). Source-rewrite hacks like the syntax-transform patches make 3.1 accept some 1.8 grammar. But they break in subtle ways for genuinely modern games (see [Syntax transform](#syntax-transform) below).

Running each game on its actual native Ruby is the only honest fix.

## Architecture

### Per-version merged.o

The build links each Ruby version's binding code + libruby + extensions into one relocatable object file with hidden symbol islanding:

```text
ios/Dependencies/build-${SDK}/lib/
  mkxp18-merged.o   exports: _mkxp_get_script_binding_18
  mkxp19-merged.o   exports: _mkxp_get_script_binding_19
  mkxp31-merged.o   exports: _mkxp_get_script_binding_31
```

The three objects link into `MkxpCore.framework`. The `ld -r -unexported_symbols_list` step hides every Ruby internal symbol, so the three versions do not clash at link time. Each `.o` exports exactly one global: the entry point that returns its version's `ScriptBinding` vtable. `mkxp-z-apple-mobile/tools/generate-ruby-unexports.sh` generates the unexports from the per-version libruby + ext archives.

Build targets: `make mkxp18-merged`, `mkxp19-merged`, `mkxp31-merged`, or `mkxp-merged` for all three. See `ios/Dependencies/common.make` for the recipes.

### Dispatcher

The host (Empo iOS app) tells the engine which Ruby version to use before each session. `MkxpCore.launch(_:)` sends plain string settings through `gamecore_setSetting`, before `gamecore_applySessionConfig`:

```c
gamecore_setSetting("rubyVersion", "31");         // "18", "19" or "31"
gamecore_setSetting("syntaxTransform", "legacy"); // or "modern"
gamecore_applySessionConfig(&config);             // directories, alignment
gamecore_setGamePath(...);                        // session starts
```

The app does not know these keys. Only `MkxpCore` sends them, and `mkxp_setSetting` in `app_bridge.cpp` reads them. `mkxp_setSetting` calls the engine setters `mkxp_setActiveRubyVersion` and `mkxp_setSyntaxTransformMode`.

`mkxp-z-apple-mobile/src/binding.h`'s `getActiveScriptBinding()` reads the atomic and calls the matching `_mkxp_get_script_binding_NN()` entry point. If the requested version's merged.o is a build-time stub (returns nullptr), the dispatcher falls back to the next available version with a warning.

`MKXP_RUBY_UNSET` keeps the legacy direct-link 3.1 path. It stays so that desktop and test-harness builds that do not drive the bridge work without changes.

### Detection

`ios/GameProbe/Sources/GameProbe/GameScriptProfile.swift` decides which Ruby version a game wants and whether the scripts look modern (one directory walk). The decision tree follows, and the first decisive signal wins:

1. **Bundled `*-rubyXYZ.dll`** at the project root: `x64-msvcrt-ruby310.dll`, `msvcrt-ruby187.dll`, `ruby193.dll`, etc. The three-digit suffix decodes:
   - `1, 8` → 18
   - `1, 9` → 19
   - `2, X` → 31 (Ruby 2.x is syntactically Ruby-3-shaped, closest available)
   - `3, 0` → 31 (folded, native 3.0 build removed)
   - `3, X` (X ≥ 1) → 31

   When a game bundles multiple DLLs, the highest version wins. Modern PE forks ship the mkxp-z runtime, which links against `x64-msvcrt-ruby310.dll`. Their `Game.ini` `Library=` field stays at the vestigial `RGSS104E.dll`, but the actual runtime is the bundled DLL. This signal is the strongest practical evidence of the Ruby version the developer tested against.

2. **Script grammar sniff** via `RubyScriptGrammarSniffer.swift`. The sniffer decodes `Scripts.{rxdata,rvdata,rvdata2}` (Marshal + zlib) and reads loose `.rb` files. Modern Ruby 3.x tokens (`&.`, pattern-match `case ... in`, endless `def`, numbered block params, kwarg shorthand, `Hash#except`, `Array#filter_map`) give **31**. Legacy source that calls `force_encoding` or `Encoding::` without a `respond_to?` or `defined?` check gives **31** with the legacy transform, unless the data file is `.rvdata2` (19). Other legacy source uses the data file extension as a prior. An inconclusive result (encrypted archive, or scripts packed in `Data/*.fpk`) falls through.

3. **RGSS archive at project root**: `.rgssad` → 18, `.rgss2a` → 18, `.rgss3a` → 19. This signal applies when scripts live inside the encrypted archive and the sniffer cannot reach them.

4. **`Game.ini` `Library=`** field: `RGSS1*` / `RGSS2*` → 18, `RGSS3*` → 19.

5. **Default**: 31. The build's historical fallback for projects that do not match any signal.

The user can override the result with the Ruby version picker. `MkxpSettings.rubyVersionOverride` holds the choice, and it wins over the scan at launch.

### Detection schema versioning

`GameScriptProfile.Schema` is a string-backed enum that identifies the heuristic set. Cases are strict supersets:

```swift
enum Schema: String {
    case initial = "initial"
    case bundledRubyDLL = "bundled-ruby-dll"
    case noStandaloneFramework = "no-standalone-framework"
    case dropRuby30 = "drop-ruby-30"
    case tightenGrammarSniff = "tighten-grammar-sniff"
    case unified = "unified"
    case sourceOverPackaging = "source-over-packaging"
    case rgss2Ruby18 = "rgss2-ruby18"  // RGSS2 on 1.8, `def` stat method is not an endless def
    case mixedRuby31 = "mixed-ruby31"  // current: legacy scripts with 1.9 encoding calls on 3.1
}

static let currentSchema: Schema = .mixedRuby31
```

`MkxpProfile` stores the scan result, its schema string, and a digest of the files that the scan reads in `Metadata/mkxp-profile.json`. The digest holds the path, size, and modification date of each file in the game folder and in `Data/`, and of the `.rb` files that the scan reads in the loose script folders (`GameScriptProfile.inputFiles`). `MkxpProfile.load(for:)` scans again when the schema or the digest is different. The import and the settings reset always scan again, because an archive keeps the dates of its files. `GameScriptProfile` is the only entry point.

## Per-version compile

Each Ruby version's binding objects compile against that version's headers. `mkxp-z-apple-mobile/tools/build-binding-ios.sh` owns the recipe. It takes the version as an argument and sets the matching defines:

```sh
mkxp-z-apple-mobile/tools/build-binding-ios.sh --ruby 18 --sdk iphonesimulator ...
mkxp-z-apple-mobile/tools/build-binding-ios.sh --ruby 19 --sdk iphonesimulator ...
mkxp-z-apple-mobile/tools/build-binding-ios.sh --ruby 31 --sdk iphonesimulator ...
```

`ios/Dependencies/common.make` calls it three times and supplies only the SDK, the libruby archives, and the dependency header dirs.

The same `binding/*.cpp` source compiles three times. Version-conditional code lives in `binding-util.h` (`mkxpUsingRuby18Encoding`, RAPI shims) and `binding-mri.cpp` (legacy method shims gated on the RAPI version).

The build isolates includes under `$(INCLUDEDIR)/ruby${VER}/`, so 1.8 and 1.9 do not see 3.1 headers.

## Syntax transform

The Ruby 3.1 build applies a set of parser patches (36 files under `mkxp-z-apple-mobile/syntax-transform/3.1/`, originally [PR #304 by white-axe](https://github.com/mkxp-z/mkxp-z/pull/304)). These patches teach Ruby 3.1's parser to also accept Ruby 1.8 grammar. The 1.8 and 1.9 builds do not apply them. Those interpreters parse their native grammar without modification.

### Why it exists

Multi-Ruby native dispatch covers most of the compatibility space. But it does not cover one shape of game: mixed-grammar Pokemon Essentials forks that combine Ruby 1.8-era syntax with 1.9+ runtime methods.

Concretely:

- **Ruby 1.8 syntax**: `when X:` (colon-terminated when clause), `break` from inside a `Proc.new` block, `?A` evaluated to an integer character code, `Object#id`, `Array#choice`, `Symbol#to_i`.
- **Ruby 1.9+ runtime methods**: `String#force_encoding`, `String#encode`, modern `Time` API, `Encoding` constants.

A single interpreter that accepts both does not exist:

- Ruby 1.8 native parses the syntax fine but lacks the runtime methods (no `force_encoding`).
- Ruby 3.1 native has all the runtime methods but its parser rejects `when X:` outright.

Ruby 3.1 with the syntax-transform parser patches is the only path that runs these games. The patches activate selectively at parse time, gated by a global. The runtime methods stay plain Ruby 3.1.

### Why only on Ruby 3.1

The 1.8 and 1.9 builds do not need the patches. Each of those interpreters runs games written in its own native grammar (via the multi-Ruby dispatcher), so there is no parser-mismatch problem to solve.

The patches themselves target Ruby 3.1's parser internals (`parse.y`, `compile.c`, `vm_method.c`, etc.). A port to 1.9 requires a re-derivation of all 36 patches against a different parser tree, for no gain.

### When it activates

The host sets the mode per session, before `gamecore_setGamePath()`:

| Mode                             | When                                                                                                                                      | Effect                                                                                              |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `MKXP_SYNTAX_TRANSFORM_DISABLED` | Game routes to Ruby 3.1 and `useModernRuby = true` (auto-detected, or manually picked)                                                    | Plain Ruby 3.1 parsing. The game must use modern grammar.                                                  |
| `MKXP_SYNTAX_TRANSFORM_LEGACY`   | Game routes to Ruby 3.1 and `useModernRuby = false` (default for mixed-grammar PE forks)                                                  | Patches active. Parser accepts 1.8 grammar.                                                         |
| `MKXP_SYNTAX_TRANSFORM_CUSTOM`   | Never set by the iOS host. Selected via mkxp.json's `syntaxTransformCustomVersion{Major,Minor,Teeny}` keys (desktop / test-harness path). | Patches active. They emulate the grammar of the configured Ruby version.                            |
| `MKXP_SYNTAX_TRANSFORM_UNSET`    | Default at startup. The engine falls back to mkxp.json's value (legacy desktop path).                                                     | The iOS host always sets a real value, so UNSET stays as a guard for desktop / test-harness builds. |

`MkxpSettings.useModernRuby` is the per-game switch. `MkxpCore.didImport` sets it to true on a new import when the scan finds Ruby 3 scripts, and for a JoiPlay archive of type `mkxp-z`. The scan reads the grammar first, then the packaging (bundled Ruby 3 runtime, `.fpk` archive) when it cannot read the scripts. The user can change it in the per-game settings sheet.

When the build does not define `MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES`, the patches are no-ops at the engine level. The 1.8 and 1.9 builds do not define it. Only the Ruby 3.1 build does.

## Quit handling and cross-session play

See [`multi-session.md`](multi-session.md). It covers the `exit!` and `Thread.critical` parts of `platform_compat.rb`, and why Empo plays one game for each process.

## Files

- **Engine**:
  - `mkxp-z-apple-mobile/binding/binding-mri.cpp` - script eval loop, `mkxp_get_script_binding_NN` entry, syntax-transform-gated legacy method shims.
  - `mkxp-z-apple-mobile/binding/binding-util.{h,cpp}` - per-version RAPI shims, `mkxpUsingRuby18Encoding`.
  - `mkxp-z-apple-mobile/src/binding.h` - `getActiveScriptBinding()` dispatcher.
  - `mkxp-z-apple-mobile/src/app_bridge.{h,cpp}` - `MKXPRubyVersion`, the `rubyVersion` and `syntaxTransform` keys of `mkxp_setSetting()`.
  - `mkxp-z-apple-mobile/src/main.cpp` - `EngineHost` lifecycle, RGSS thread.
  - `mkxp-z-apple-mobile/syntax-transform/3.1/*.patch` - 36 Ruby 3.1 source patches.
  - `mkxp-z-apple-mobile/scripts/preload/platform_compat.rb` - Thread.critical / exit! shims.
- **Build**:
  - `mkxp-z-apple-mobile/tools/build-binding-ios.sh` - the per-version merged.o recipe.
  - `mkxp-z-apple-mobile/multiruby/wrapper.cpp` - the one exported entry point per version.
  - `mkxp-z-apple-mobile/deps/common.make` - per-version Ruby builds, and the calls into the engine recipe.
  - `mkxp-z-apple-mobile/deps/apply-ruby-patches.sh` - manifest-driven patch application.
  - `mkxp-z-apple-mobile/tools/generate-ruby-unexports.sh` - symbol-islanding helper.
  - `mkxp-z-apple-mobile/deps/sources/ruby{,18,19}/` - Ruby submodules. `sources/ruby` is 3.1.
- **iOS**:
  - `ios/GameProbe/Sources/GameProbe/GameScriptProfile.swift` - unified per-game detection.
  - `ios/GameProbe/Sources/GameProbe/RubyScriptGrammarSniffer.swift` - Marshal + zlib decoder for Scripts.\* files.
  - `ios/Empo/src/Cores/Mkxp/MkxpCore.swift` - `launch(_:)` sends the Ruby settings, `didImport` pins Modern.
  - `ios/Empo/src/Cores/Mkxp/MkxpProfile.swift` - stored scan result + schema string.
  - `ios/Empo/src/Cores/Mkxp/MkxpSettings.swift` - `rubyVersionOverride` + `useModernRuby` per-game settings.

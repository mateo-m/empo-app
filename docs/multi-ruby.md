# Multi-Ruby

## Overview

Empo ships three Ruby interpreters in one binary: 1.8.8, 1.9.3, and 3.1.3. At launch, it dispatches each game to the correct one. A vintage RPG Maker XP game runs on Ruby 1.8's actual parser and VM. A modern Pokemon Essentials fork built on the mkxp-z runtime routes to Ruby 3.1. Empo applies the syntax-transform compatibility mode for the legacy game-script idioms that PE uses. Modern forks that ship `x64-msvcrt-ruby300.dll` fold onto the same 3.1 dispatch. The syntax-transform parser patches only exist in the 3.1 source, so a separate 3.0 build was a silent no-op for legacy compatibility. Empo dropped it.

This replaces the older "everything on one Ruby" architecture (originally 1.8-only, briefly 3.1-only via the syntax-transform PR304 experiment).

## Why

Different RPG Maker generations target different Ruby versions:

| Generation               | Engine DLL                       | Ruby version | Typical games                                                                                                           |
| ------------------------ | -------------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------- |
| RGSS1 (RPG Maker XP)     | `RGSS104E.dll`                   | 1.8          | Vintage Pokemon Essentials forks                                                                                        |
| RGSS2 (RPG Maker VX)     | `RGSS200J.dll`                   | 1.9          | A handful of community projects                                                                                         |
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

The `ld -r --unexported_symbols_list` step hides every Ruby internal symbol, so the three versions do not clash at link time. Each `.o` exports exactly one global: the entry point that returns its version's `ScriptBinding` vtable. `ios/Dependencies/tools/generate-ruby-unexports.sh` generates the unexports from the per-version libruby + ext archives.

Build targets: `make mkxp18-merged`, `mkxp19-merged`, `mkxp31-merged`, or `mkxp-merged` for all three. See `ios/Dependencies/common.make` for the recipes.

### Dispatcher

The host (Empo iOS app) tells the engine which Ruby version to use before each session, via the `app_bridge.h` API:

```c
mkxp_applySessionConfig(&(MKXPSessionConfig){
    .rubyVersion = MKXP_RUBY_31,
    .syntaxTransformMode = MKXP_SYNTAX_TRANSFORM_LEGACY,
    /* managedConfigDir, userDataDirectory, alignment, ... */
});
mkxp_setGamePath(...);  // session starts
```

Individual setters (`mkxp_setActiveRubyVersion`, `mkxp_setSyntaxTransformMode`, …) remain for mid-session toggles. `GameSession.configureEngine()` prefers `mkxp_applySessionConfig()` at launch.

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

2. **Script grammar sniff** via `RubyScriptGrammarSniffer.swift`. The sniffer decodes `Scripts.{rxdata,rvdata,rvdata2}` (Marshal + zlib) and reads loose `.rb` files. Modern Ruby 3.x tokens (`&.`, pattern-match `case ... in`, endless `def`, numbered block params, kwarg shorthand, `Hash#except`, `Array#filter_map`) give **31**. Pure-legacy source uses the data file extension as a prior. An inconclusive result (encrypted archive) falls through.

3. **RGSS archive at project root**: `.rgssad` → 18, `.rgss2a` → 19, `.rgss3a` → 19. This signal applies when scripts live inside the encrypted archive and the sniffer cannot reach them.

4. **`Game.ini` `Library=`** field: `RGSS1*` → 18, `RGSS2*` / `RGSS3*` → 19.

5. **Default**: 31. The build's historical fallback for projects that do not match any signal.

The user can override the result with the Ruby Version picker in `GameSettings`. The override wins over auto-detection at engine-launch time.

### Detection schema versioning

`GameScriptProfile.Schema` is a string-backed enum that identifies the heuristic set. Cases are strict supersets:

```swift
enum Schema: String {
    case initial = "initial"
    case bundledRubyDLL = "bundled-ruby-dll"
    case noStandaloneFramework = "no-standalone-framework"
    case dropRuby30 = "drop-ruby-30"
    case tightenGrammarSniff = "tighten-grammar-sniff"
    case unified = "unified"  // current: one sniff for version + modern scripts
}

static let currentSchema: Schema = .unified
```

`GameMetadata` persists the detected version and `modernRubyScriptsDetected` alongside the `*DetectedSchema` raw strings. Library load compares the stored schema with the current one. On a mismatch, it re-runs detection. `RubyVersionDetection` remains as a thin delegate to `GameScriptProfile` for call-site compatibility.

`GameMetadata.init(from:)` is a manual implementation with field-level `try?`. A single field's type change between builds thus does not erase unrelated fields (`dateAdded`, `totalPlayTime`, etc.) on the next save.

## Per-version compile

Each Ruby version's binding objects compile against that version's headers:

```make
MKXPZ_DEFINES_18 := -DMKXPZ_RUBY_VERSION_MAJOR=1 -DMKXPZ_RUBY_VERSION_MINOR=8 ...
MKXPZ_DEFINES_19 := -DMKXPZ_RUBY_VERSION_MAJOR=1 -DMKXPZ_RUBY_VERSION_MINOR=9 ...
MKXPZ_DEFINES_31 := -DMKXPZ_RUBY_VERSION_MAJOR=3 -DMKXPZ_RUBY_VERSION_MINOR=1 ...
```

The same `binding/*.cpp` source compiles three times. Version-conditional code lives in `binding-util.h` (`mkxpUsingRuby18Encoding`, RAPI shims) and `binding-mri.cpp` (legacy method shims gated on the RAPI version).

The build isolates includes under `$(INCLUDEDIR)/ruby${VER}/`, so 1.8 and 1.9 do not see 3.1 headers.

## Syntax transform

The Ruby 3.1 build applies a set of parser patches (34 files under `mkxp-z-apple-mobile/syntax-transform/3.1/`, originally [PR #304 by white-axe](https://github.com/mkxp-z/mkxp-z/pull/304)). These patches teach Ruby 3.1's parser to also accept Ruby 1.8 grammar. The 1.8 and 1.9 builds do not apply them. Those interpreters parse their native grammar without modification.

### Why it exists

Multi-Ruby native dispatch covers most of the compatibility space. But it does not cover one shape of game: mixed-grammar Pokemon Essentials forks that combine Ruby 1.8-era syntax with 1.9+ runtime methods.

Concretely:

- **Ruby 1.8 syntax**: `when X:` (colon-terminated when clause), `break` from inside a `Proc.new` block, `?A` evaluated to an integer character code, `Object#id`, `Array#choice`, `Symbol#to_i`.
- **Ruby 1.9+ runtime methods**: `String#force_encoding`, `String#encode`, modern `Time` API, `Encoding` constants.

A single interpreter that accepts both does not exist:

- Ruby 1.8 native parses the syntax fine but lacks the runtime methods (no `force_encoding`).
- Ruby 3.1 native has all the runtime methods but its parser rejects `when X:` outright.

Ruby 3.1 with the syntax-transform parser patches is the only path that runs these games. The patches activate selectively at parse time, gated by a global. The runtime methods stay vanilla Ruby 3.1.

### Why only on Ruby 3.1

The 1.8 and 1.9 builds do not need the patches. Each of those interpreters runs games written in its own native grammar (via the multi-Ruby dispatcher), so there is no parser-mismatch problem to solve.

The patches themselves target Ruby 3.1's parser internals (`parse.y`, `compile.c`, `vm_method.c`, etc.). A port to 1.9 requires a re-derivation of all 34 patches against a different parser tree, for no gain.

### When it activates

The host sets the mode per session, before `mkxp_setGamePath()`:

| Mode                             | When                                                                                                                                      | Effect                                                                                              |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `MKXP_SYNTAX_TRANSFORM_DISABLED` | Game routes to Ruby 3.1 and `useModernRuby = true` (auto-detected, or manually picked)                                                    | Vanilla Ruby 3.1 parsing. Modern grammar required.                                                  |
| `MKXP_SYNTAX_TRANSFORM_LEGACY`   | Game routes to Ruby 3.1 and `useModernRuby = false` (default for mixed-grammar PE forks)                                                  | Patches active. Parser accepts 1.8 grammar.                                                         |
| `MKXP_SYNTAX_TRANSFORM_CUSTOM`   | Never set by the iOS host. Selected via mkxp.json's `syntaxTransformCustomVersion{Major,Minor,Teeny}` keys (desktop / test-harness path). | Patches active. They emulate the grammar of the configured Ruby version.                            |
| `MKXP_SYNTAX_TRANSFORM_UNSET`    | Default at startup. The engine falls back to mkxp.json's value (legacy desktop path).                                                     | The iOS host always sets a real value, so UNSET stays as a guard for desktop / test-harness builds. |

`GameSettings.useModernRuby` is the per-game switch. `GameScriptProfile` and JGP import paths set it at import time from heuristics (bundled DLL filename, grammar sniff, `.fpk` packaging). The user can override it in the per-game settings sheet.

When the build does not define `MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES`, the patches are no-ops at the engine level. The 1.8 and 1.9 builds do not define it. Only the Ruby 3.1 build does.

### History

A previous iteration tried to strip the syntax-transform patches, on the assumption that multi-Ruby native dispatch made them dead code. The assumption was wrong: mixed-grammar Pokemon Essentials forks need the patched parser. The strip experiment was reverted.

## Quit handling

Ruby's `Kernel.exit!` and `Process.exit!` skip `at_exit` handlers and bypass the engine's SystemExit catch entirely. They call C `_exit(status)` directly. This ends the iOS process before mkxp-z can save the engine log, fire the `mkxp_setEngineTerminated` callback, or do anything else.

Pokemon Essentials' `pbExit` and various forks of it commonly use `exit!` to skip a "press any key to confirm" splash. On desktop, that is a fine UX choice. On iOS, it makes the app vanish silently: status 1, no signal, no crash report. Apple's App Store review guideline 2.5.1 also explicitly forbids programmatic process termination, so the `exit!` path needs interception in any case.

`scripts/preload/platform_compat.rb` redirects `Kernel.exit!` and `Process.exit!` to `Kernel.exit`. The engine's SystemExit catch in `binding-mri.cpp`'s eval loop then runs and sets `mkxp_setEngineExitedCleanly()`. The iOS host's clean-exit alert ("close from app switcher") appears as designed.

The same preload also restores `Thread.critical` / `Thread.critical=` as no-ops on Ruby 1.9+. Vintage RGSS code wraps Marshal.load and save-file I/O in `Thread.critical = true` blocks (a 1.8 cooperative-scheduling idiom). Without the shim, Ruby 1.9+ raises NoMethodError mid-quit, and the error escapes the script-eval loop. `SharedState::finiInstance()` then segfaults on iOS during graphics teardown with a pending Ruby exception.

## Cross-session play

Currently disabled. After a clean engine exit, the iOS host shows an alert ("The game has ended or requested a restart. Close Empo from the app switcher and reopen it to continue.") instead of returning to the library. Cross-session reuse of a Ruby VM with a different game's scripts is fragile: the previous session's class definitions leak into the next session and cause superclass-mismatch errors and weirder issues.

A previous iteration shipped aggressive cross-session cleanup (constant-baseline diffing, singleton-method scrubbing, intrusive-list detachment for disposables, etc.). It worked for narrow game pairs but did not survive contact with a broader corpus, especially across different Ruby versions. Until that cleanup is reliable, the app asks the user to force-close and relaunch.

Same-game re-entry is safe in principle (no class leak). But the iOS layer currently cannot tell it apart from a different-game pick. See `docs/multi-session.md` for the engine-side teardown sequence.

## Files

- **Engine**:
  - `mkxp-z-apple-mobile/binding/binding-mri.cpp` - script eval loop, `mkxp_get_script_binding_NN` entry, syntax-transform-gated legacy method shims.
  - `mkxp-z-apple-mobile/binding/binding-util.{h,cpp}` - per-version RAPI shims, `mkxpUsingRuby18Encoding`.
  - `mkxp-z-apple-mobile/src/binding.h` - `getActiveScriptBinding()` dispatcher.
  - `mkxp-z-apple-mobile/src/app_bridge.{h,cpp}` - `MKXPRubyVersion`, `mkxp_setActiveRubyVersion()` / `mkxp_setSyntaxTransformMode()`.
  - `mkxp-z-apple-mobile/src/main.cpp` - `EngineHost` lifecycle, RGSS thread.
  - `mkxp-z-apple-mobile/syntax-transform/3.1/*.patch` - 34 Ruby 3.1 source patches (kept).
  - `mkxp-z-apple-mobile/scripts/preload/platform_compat.rb` - Thread.critical / exit! shims.
- **Build**:
  - `ios/Dependencies/common.make` - per-version Ruby + merged.o build recipes.
  - `ios/Dependencies/apply-ruby-patches.sh` - manifest-driven patch application.
  - `ios/Dependencies/tools/generate-ruby-unexports.sh` - symbol-islanding helper.
  - `ios/Dependencies/sources/ruby{,18,19}/` - Ruby submodules. `sources/ruby` is 3.1.
- **iOS**:
  - `ios/GameProbe/Sources/GameProbe/GameScriptProfile.swift` - unified per-game detection.
  - `ios/GameProbe/Sources/GameProbe/RubyScriptGrammarSniffer.swift` - Marshal + zlib decoder for Scripts.\* files.
  - `ios/Empo/src/App/GameSession.swift` - `configureEngine()` before `mkxp_setGamePath`.
  - `ios/Empo/src/Library/GameMetadata.swift` - persisted detection result + schema string.
  - `ios/Empo/src/Library/GameSettings.swift` - `rubyVersionOverride` + `useModernRuby` per-game settings.

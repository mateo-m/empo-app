# Ruby 3.1 + syntax transform

## Status

Shipped. Ruby 3.1 is one of four interpreters Empo now ships in the same binary, alongside 1.8 / 1.9 / 3.0. The syntax-transform PR304 patches landed and stayed - they're applied to the Ruby 3.1 build only, gated per-game via `mkxp_setSyntaxTransformMode()`.

For the architecture, see `multi-ruby.md`.

## What this doc records

The original experiment was "replace Ruby 1.8 with Ruby 3.1 + syntax-transform across the board." That hypothesis was tested, and it didn't survive contact with real games. The findings:

1. **Ruby 1.8 native still has a job.** Pokemon Z, Insurgence, Uranium and other vintage XP forks run cleanly on actual 1.8.7 and don't benefit from running through transformed 3.1. Native parses faster, fewer surprises, smaller binaries (libruby18-static.a is 1.7 MB vs Ruby 3.1's 17 MB).

2. **Ruby 3.1 native (without transform) doesn't cover legacy-grammar games.** Vinemon Sauce Edition mixes Ruby 1.8 syntax (`when X:`, `break` from proc-closure) with Ruby 1.9+ runtime methods (`force_encoding`). It can't run on 1.8 native (no `force_encoding`) or vanilla 3.1 (parser rejects `when X:`). Patched 3.1 with the transform in LEGACY mode is the only working path.

3. **Multi-Ruby beats one-Ruby for both code size and correctness.** Each game runs on the closest native parser; the transform is only on the 3.1 build, only activated for games that demonstrably need it.

4. **Transform stripping is a trap.** When the multi-Ruby work seemed mature, we tried removing the syntax-transform patches under the assumption they were dead code. They aren't - mixed-grammar PE forks rely on them. The strip experiment was reverted.

## Detection

Runs at game import time, persisted on `GameMetadata.rubyVersion`:

| Marker | Routes to |
|---|---|
| PSDK directories (`Data/PSDK/`, `project.studio`) | Ruby 3.0 |
| Bundled `x64-msvcrt-rubyXYZ.dll` | Ruby per filename suffix |
| Modern grammar tokens (`&.`, pattern match, endless def) in script | Ruby 3.1 |
| `.rgssad` archive | Ruby 1.8 |
| `.rgss2a` / `.rgss3a` archive | Ruby 1.9 |
| `Game.ini` `Library=RGSS1*` | Ruby 1.8 |
| `Game.ini` `Library=RGSS2*` / `RGSS3*` | Ruby 1.9 |
| Default | Ruby 3.1 |

User can override via the Ruby Version picker in the per-game Settings sheet. See `multi-ruby.md` for the full decision tree and schema-versioning logic.

## What the syntax transform does on Ruby 3.1

Each game routed to Ruby 3.1 picks one of two transform modes via `mkxp_setSyntaxTransformMode`:

- **DISABLED** (modern PE forks) - vanilla Ruby 3.1 parsing. `useModernRuby = true` auto-detected when the game ships a modern Ruby DLL, an `.fpk` script archive, or loose `.rb` files containing kwarg shorthand.
- **LEGACY** (mixed-grammar PE forks like Vinemon) - 33 parser patches activate, accepting Ruby 1.8 syntax (`when X:`, character literals as Integer, `Object#id`, `Symbol#to_i`, etc.) on top of the Ruby 3.1 runtime.

The `MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES` define is the build-side switch; it's set for the 3.1 binding compile only. Without it, the patches and gates are no-ops and Ruby 3.1 behaves as upstream.

## Files

- `mkxp-z-apple-mobile/syntax-transform/3.1/0000-prelude.patch` ... `0032-toplevel-def-visibility.patch` - the 33 patches.
- `mkxp-z-apple-mobile/binding/binding-mri.cpp` - `legacy_*` C method shims (Array#choice, Hash#index, Object#id, etc.) gated on `MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES` + `mkxp_ec_is_syntax_transform_active`.
- `mkxp-z-apple-mobile/src/main.cpp` - `initSyntaxTransform()` reads the bridge mode, sets the `mkxp_syntax_transform_target_ruby_version_*` globals.
- `mkxp-z-apple-mobile/src/app_bridge.{h,cpp}` - `MKXPSyntaxTransformMode` enum + setter/getter.
- `ios/Empo/src/Library/GameSettings.swift` - `useModernRuby` field, `resolveSyntaxTransformMode()`, `detectModernRubyScripts()` heuristic.

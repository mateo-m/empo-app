# Ruby 3.1 + syntax transform experiment

Live branch: `experiment/ruby31-syntax-transform` in both repos.
Goal: replace Ruby 1.8 with Ruby 3.1 + white-axe's syntax transform (mkxp-z PR #304), validate against Pokemon Z and Uranium, decide whether to keep.

If it doesn't work with those two games, we abandon the branch and go back to 1.8 on `main`.

## Approach

Clean slate. All Ruby-1.8-specific code comes out. PR #304 goes in verbatim. No dual-runtime, no toggle, no fallback in the binary itself. The fallback is "revert the branch."

## What gets ripped out

- `libruby18-static.a`, `libruby18-ext.a`, `ios/Dependencies/sources/ruby18`
- `MKXPZ_LEGACY_RUBY` define + every `#if` that depends on it
- `RAPI_FULL` clamping to 187
- `rb_gc_stack_start` force-update in session setup
- 4 MB thread stack for RGSS (Ruby 3.1's GC is precise, 512 KB is fine)
- VM-persistence hack (Ruby 3.1 supports `ruby_cleanup()`/`ruby_init()`)
- `scripts/preload/ruby_classic_wrap.rb` (replaced by PR #304 C-level shims)
- `scripts/preload/win32_wrap.rb` — may need revisiting on 3.1

## What comes in from PR #304

- 29 Ruby source patches in `syntax-transform/3.1/` applied at build time
- Engine-side: `mkxp_syntax_transform_next_eval`, `mkxp_ec_is_syntax_transform_active`, `mkxp_str_new`/`mkxp_str_new_cstr`, legacy bindings (`Array#choice`, `Hash#index`, `Object#id`, etc.)
- Config: `syntaxTransform` (0/1/2), `syntaxTransformCustomVersion{Major,Minor,Teeny}` in mkxp.json
- `initSyntaxTransform()` in `main.cpp` wires it to RGSS version

## Phases

1. Scout + branches (done)
2. Engine merge + Ruby 3.1 build with patches
3. App wiring, compile, link
4. Multi-session cleanup rewrite for Ruby 3.1
5. Test with Pokemon Z + Uranium
6. Decide: merge to main, or revert branch

Hard bail: if Ruby 3.1 + patches won't build in 2 hrs, we stop.

## Known risks

- Ruby 3.1 is ~4x larger than 1.8. IPA will grow significantly.
- 29 patches to `parse.y` / `compile.c` / `vm_*.c` — any single one failing to apply is a blocker.
- Multi-session on 3.1 is untested territory. The Pokemon games may hit Ruby state that doesn't cleanly reset even with `ruby_cleanup()`.
- `pokemon_compat.rb` / `pokemon_input.rb` still needed — they patch game-level quirks, not Ruby-level.

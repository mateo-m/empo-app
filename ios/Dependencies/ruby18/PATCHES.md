# Ruby 1.8 — Patches & Build Notes

## Source

- **Upstream**: JoiPlay's `ruby_1_8` branch — <https://github.com/joiplay/ruby>
- **Branch**: `ruby_1_8` (submodule at `sources/ruby18`)
- **Commit**: `50783b8` ("\* 2014-01-28") — a git-svn mirror of the official Ruby SVN repository (revision 44718)
- **Note**: This is the last maintenance snapshot of Ruby 1.8, frozen since 2014.

## Why Ruby 1.8?

Most RPG Maker XP games (RGSS1) were written against Ruby 1.8. mkxp-z
normally ships with Ruby 3.1, but many older games break on it due to
syntax and API changes (e.g. `when` clause colon syntax, `Hash` ordering,
removed `Fixnum`/`Bignum` classes, string encoding changes). Using the
original Ruby 1.8 maximizes game compatibility.

## Patches

All iOS patches are in `ios.patch` (applied automatically by the makefile
via `git apply` before `autoconf`):

### `config.guess` and `config.sub` — Updated for aarch64

The original 2014-era autoconf helper scripts do not recognize modern
platform triplets like `aarch64-apple-darwin`. Both files were replaced
with current versions from the GNU config project so that `./configure
--host=aarch64-apple-darwin` works correctly.

These are the ONLY modifications to the JoiPlay Ruby 1.8 source.

### Engine-side accommodations (in mkxp-z, not in Ruby source)

These are not patches to Ruby itself, but critical engine adaptations
required to make Ruby 1.8 work on iOS:

1. **4MB RGSS thread stack** — Ruby 1.8's GC (`mark_locations_array`)
   scans the entire thread stack for object references. The default 512KB
   iOS pthread stack causes SIGBUS when GC hits the guard page. Fixed by
   using `SDL_CreateThreadWithStackSize` with 4MB.

2. **GC stack base update** — `rb_gc_stack_start` (global in `gc.c`)
   records the stack base at `ruby_init()` time. Since `ruby_init()` is
   only called once (CRuby 1.8 cannot be restarted), subsequent RGSS
   threads have different stacks but GC still scans the old one, causing
   SIGSEGV. Fixed by force-updating `rb_gc_stack_start` at the start of
   each session via `extern VALUE *rb_gc_stack_start`.

3. **VM persistence** — CRuby 1.8's VM cannot be restarted
   (`ruby_cleanup()` + `ruby_init()` causes SIGSEGV). The engine calls
   `ruby_init()` and `Init_*()` only once, and on subsequent game
   sessions clears leftover Ruby state with `rb_eval_string_protect`.

4. **RAPI clamping** — `RAPI_FULL=188` is clamped to `187` so the engine
   selects the RGSS1 binding codepath.

## iOS Build Instructions

Ruby 1.8 is now built as part of the standard makefile system:

```bash
cd ios/Dependencies
make -f iphoneos.make ruby18       # device build
make -f iphonesimulator.make ruby18  # simulator build
```

Or as part of the full build:

```bash
make -f iphoneos.make everything
```

The makefile automatically:
1. Applies `ios.patch` via `git apply` (updates config.guess/config.sub)
2. Runs `autoconf` to generate `configure`
3. Cross-compiles with `-std=gnu89` and appropriate `-Wno-*` flags
4. Builds core library (`libruby18-static.a`)
5. Builds extensions (zlib, stringio, strscan, thread, digest, fcntl) into `libruby18-ext.a`
6. Installs libs to `$(LIBDIR)` and headers to `$(INCLUDEDIR)/ruby18/`

### Key build flags

- `-std=gnu89` — Required because Ruby 1.8 is K&R-style C code
- `-Wno-implicit-function-declaration`, `-Wno-implicit-int`, etc. —
  Suppress warnings-turned-errors for legacy C code
- `--host=aarch64-apple-darwin --build=x86_64-apple-darwin` —
  Cross-compilation triple

### Output

| Artifact             | Description                                                           |
| -------------------- | --------------------------------------------------------------------- |
| `libruby18-static.a` | Core Ruby 1.8 interpreter (VM, parser, GC, core classes)              |
| `libruby18-ext.a`    | Bundled C extensions (zlib, stringio, strscan, thread, digest, fcntl) |
| `include/ruby18/*.h` | 17 public headers (ruby.h, intern.h, etc.)                            |

### Linking

In the Xcode project (`project.yml`), Ruby 1.8 is linked via:

```yaml
OTHER_LDFLAGS:
  - -lruby18-static
  - -lruby18-ext
```

Header search path: `$(DEPENDENCY_SEARCH_PATH)/include/ruby18`

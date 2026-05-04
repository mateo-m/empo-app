# Ruby 1.9: Patches & Build Notes

## Source

- **Upstream**: Ruby 1.9.3 (`v1_9_3_551` tag, last 1.9 release, 2014)
- **Branch**: `ruby_1_9_3` (submodule at `sources/ruby19`)
- **Commit**: `a32f378`

## Why Ruby 1.9?

Most RPG Maker VX (RGSS2) and VX Ace (RGSS3) games target Ruby 1.9.2.
Empo's multi-Ruby dispatcher routes any game whose detection signals
RGSS2/RGSS3 to this build (see `docs/multi-ruby.md`). The 1.9 series is
also what most VX Ace games were tested against, so syntax that's only
valid in 1.9 (block-local variables, `__method__`) parses correctly
without falling back to Ruby 3.1's syntax-transform patches.

## Patches

All iOS patches are in `ios.patch` (applied automatically by the
makefile via `git apply` before `autoconf`):

### `config.guess` and `config.sub`: Updated for aarch64

The 2014-era autoconf helper scripts don't recognize modern platform
triplets like `aarch64-apple-darwin`. Both files were replaced with
current GNU config versions so cross-compilation to iOS works.

### Engine-side accommodations (in mkxp-z, not in Ruby source)

These are not patches to Ruby itself, but engine-side adaptations
required for Ruby 1.9 on iOS:

1. **4MB RGSS thread stack**: Ruby 1.9's GC scans the entire thread
   stack for object references. The default 512KB iOS pthread stack
   triggers SIGBUS when GC hits the guard page. Worked around by
   calling `SDL_CreateThreadWithStackSize` with 4MB.

2. **VM persistence**: `ruby_init()` is one-shot per process; the
   engine calls it once and reuses the VM across game sessions for
   the lifetime of the app.

## iOS build instructions

```bash
cd ios/Dependencies
make -f iphoneos.make ruby19          # device build
make -f iphonesimulator.make ruby19   # simulator build
```

The makefile:

1. Applies `ios.patch` (config.guess/config.sub bumps)
2. Runs `autoconf` to generate `configure`
3. Cross-compiles with the iOS toolchain
4. Builds the core library (`libruby19-static.a`)
5. Builds bundled extensions (zlib, stringio, strscan, thread, digest,
   fcntl) into `libruby19-ext.a`
6. Installs libs to `$(LIBDIR)` and headers to `$(INCLUDEDIR)/ruby19/`

### Output

| Artifact             | Description                                              |
| -------------------- | -------------------------------------------------------- |
| `libruby19-static.a` | Core Ruby 1.9.3 interpreter (VM, parser, GC, core)       |
| `libruby19-ext.a`    | Bundled C extensions                                     |
| `include/ruby19/*.h` | Public headers (ruby.h, intern.h, etc.)                  |

### Linking

In `project.yml`:

```yaml
OTHER_LDFLAGS:
  - -lruby19-static
  - -lruby19-ext
```

Header search path: `$(DEPENDENCY_SEARCH_PATH)/include/ruby19`

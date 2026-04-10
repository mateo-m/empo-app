# Ruby 1.8 — Patches & Build Notes

## Source

- **Upstream**: JoiPlay's `ruby_1_8` branch — <https://github.com/joiplay/ruby>
- **Branch**: `ruby_1_8`
- **Commit**: `50783b8` ("\* 2014-01-28") — a git-svn mirror of the official Ruby SVN repository (revision 44718)
- **Note**: This is the last maintenance snapshot of Ruby 1.8, frozen since 2014.

## Why Ruby 1.8?

Most RPG Maker XP games (RGSS1) were written against Ruby 1.8. mkxp-z
normally ships with Ruby 3.1, but many older games break on it due to
syntax and API changes (e.g. `when` clause colon syntax, `Hash` ordering,
removed `Fixnum`/`Bignum` classes, string encoding changes). Using the
original Ruby 1.8 maximizes game compatibility.

## Patches

The Ruby 1.8 source is NOT included in this repository — it is built
externally. Only the pre-built static libraries and headers are consumed.

### Source modifications (2 files)

#### 1. `config.guess` and `config.sub` — Updated for aarch64

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

Ruby 1.8 is built entirely outside the project's makefile system. The
following instructions reproduce the build.

### Prerequisites

- Xcode with iOS SDK (arm64)
- The iOS dependency build prefix (for zlib headers/lib):
  `ios/Dependencies/build-iphoneos-arm64/` (or `iphonesimulator`)

### 1. Clone source

```bash
git clone -b ruby_1_8 https://github.com/joiplay/ruby /tmp/ruby18-src
cd /tmp/ruby18-src
```

### 2. Update config.guess / config.sub

Replace the 2014-era files with current versions:

```bash
curl -o config.guess 'https://git.savannah.gnu.org/cgit/config.git/plain/config.guess'
curl -o config.sub   'https://git.savannah.gnu.org/cgit/config.git/plain/config.sub'
```

### 3. Set up cross-compilation environment

```bash
SDK="iphoneos"  # or "iphonesimulator"
SYSROOT=$(xcrun --sdk $SDK --show-sdk-path)
CC=$(xcrun --sdk $SDK --find clang)
AR=$(xcrun --sdk $SDK --find ar)
RANLIB=$(xcrun --sdk $SDK --find ranlib)

ARCH_FLAGS="-arch arm64 -isysroot $SYSROOT -miphoneos-version-min=26.0"
# For simulator, use: -mios-simulator-version-min=26.0 -target arm64-apple-ios26.0-simulator

BUILD_PREFIX="/path/to/ios/Dependencies/build-iphoneos-arm64"

CFLAGS="$ARCH_FLAGS -std=gnu89 -O2 \
  -Wno-implicit-function-declaration \
  -Wno-implicit-int \
  -Wno-incompatible-pointer-types \
  -Wno-int-conversion \
  -Wno-deprecated-non-prototype \
  -Wno-incompatible-function-pointer-types \
  -I$BUILD_PREFIX/include"

LDFLAGS="$ARCH_FLAGS -L$BUILD_PREFIX/lib"
```

Key notes on CFLAGS:

- `-std=gnu89` — Required because Ruby 1.8 is K&R-style C code that
  relies on implicit function declarations and other C89 behaviors
- The `-Wno-*` flags suppress warnings-turned-errors for the legacy code
- `-I$BUILD_PREFIX/include` — Needed for zlib headers

### 4. Configure

```bash
./configure \
  --host=aarch64-apple-darwin \
  --build=x86_64-apple-darwin \
  --prefix=$BUILD_PREFIX \
  --disable-shared \
  --enable-static \
  --with-static-linked-ext \
  CC="$CC" \
  CFLAGS="$CFLAGS" \
  LDFLAGS="$LDFLAGS"
```

### 5. Build core library

```bash
make miniruby  # builds the bootstrap interpreter (not used, but required)
make libruby18-static.a
```

### 6. Build extensions

Extensions are compiled separately and archived into `libruby18-ext.a`.
The following extensions are needed by mkxp-z / RGSS games:

```bash
EXTS="zlib stringio strscan thread digest fcntl"
```

Each extension is built by compiling its `.c` files from `ext/<name>/`
with the same CFLAGS plus `-I. -I./include`, then archiving the `.o`
files:

```bash
OBJ_FILES=""
for ext in $EXTS; do
  cd ext/$ext
  # Run extconf.rb equivalent: compile all .c files
  for src in *.c; do
    $CC $CFLAGS -I../.. -I../../include -c $src -o ${src%.c}.o
    OBJ_FILES="$OBJ_FILES ext/$ext/${src%.c}.o"
  done
  cd ../..
done

$AR rcs libruby18-ext.a $OBJ_FILES
$RANLIB libruby18-ext.a
```

### 7. Install

Copy the build artifacts into the dependency build prefix:

```bash
cp libruby18-static.a $BUILD_PREFIX/lib/
cp libruby18-ext.a    $BUILD_PREFIX/lib/
mkdir -p $BUILD_PREFIX/include/ruby18
cp include/ruby/*.h   $BUILD_PREFIX/include/ruby18/
cp config.h           $BUILD_PREFIX/include/ruby18/  # generated by configure
```

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

# Pixman: patches and build notes

## Source

- **Upstream**: Pixman 0.42.2 (stock release, not a fork)
- **Tag**: `pixman-0.42.2` from <https://gitlab.freedesktop.org/pixman/pixman>

## Patches

No source modifications.

## iOS build instructions

The build uses Autotools:

```
./autogen.sh
./configure \
  --enable-static=yes \
  --enable-shared=no \
  --disable-arm-a64-neon \
  <common CONFIGURE_ARGS from common.make>
```

Key flags:

- `--disable-arm-a64-neon`: this flag avoids NEON assembly issues in the
  iOS ARM64 cross-compile. Without it, the build tries to use A64 NEON
  intrinsics, and the iOS toolchain fails to compile them.

Depends on: libpng

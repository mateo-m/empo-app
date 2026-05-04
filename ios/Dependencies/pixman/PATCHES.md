# Pixman: Patches & Build Notes

## Source

- **Upstream**: Pixman 0.42.2 (stock release, not a fork)
- **Tag**: `pixman-0.42.2` from <https://gitlab.freedesktop.org/pixman/pixman>

## Patches

No source modifications.

## iOS build instructions

Built with Autotools:

```
./autogen.sh
./configure \
  --enable-static=yes \
  --enable-shared=no \
  --disable-arm-a64-neon \
  <common CONFIGURE_ARGS from common.make>
```

Key flags:

- `--disable-arm-a64-neon`: Required to avoid NEON assembly issues when
  cross-compiling for iOS ARM64. Without this flag, the build attempts to
  use A64 NEON intrinsics that cause compilation failures with the iOS
  toolchain.

Depends on: libpng

# SDL2_ttf: Patches & Build Notes

## Source

- **Upstream**: SDL_ttf ~2.20.1
- **Fork**: <https://github.com/mkxp-z/SDL_ttf> branch `mkxp-z`
- **Base**: `release-2.20.1` tag point

## Patches

Two custom commits on top of upstream:

1. **`20e405a`** (Roza): Do not need test programs
   - Removes test program compilation from the build.
2. **`0d5909e`** (Roza): Disable NEON so it builds on ARM
   - Prevents NEON intrinsic issues during cross-compilation for ARM platforms.

## iOS build instructions

Built with Autotools:

```
./autogen.sh
./configure \
  --enable-static=true \
  --enable-shared=false \
  <common CONFIGURE_ARGS from common.make>
```

Depends on: SDL2, FreeType

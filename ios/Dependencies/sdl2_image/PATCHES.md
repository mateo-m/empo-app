# SDL2_image: patches and build notes

## Source

- **Upstream**: SDL_image ~2.6.3 (`release-2.6.0` tag + 18 upstream commits)
- **Fork**: <https://github.com/mkxp-z/SDL_image> branch `mkxp-z`
- **Top commit**: `d3c6d59` (Sam Lantinga: "Fixed Xcode DYLIB_CURRENT_VERSION")

## Patches

No mkxp-z specific source patches. The `mkxp-z` branch tracks an
upstream release point. All 18 commits above `release-2.6.0` are
standard upstream bug fixes and version bumps by Sam Lantinga.

## iOS build instructions

The build uses CMake (out-of-tree in `cmakebuild/`):

```
cmake .. \
  -DBUILD_SHARED_LIBS=no \
  -DSDL2IMAGE_JPG_SAVE=yes \
  -DSDL2IMAGE_PNG_SAVE=yes \
  -DSDL2IMAGE_PNG_SHARED=no \
  -DSDL2IMAGE_JPG_SHARED=no \
  -DSDL2IMAGE_JXL=no \
  -DSDL2IMAGE_BACKEND_IMAGEIO=no \
  -DSDL2IMAGE_VENDORED=yes \
  <common CMAKE_ARGS from common.make>
```

Key flags:

- Static build with vendored sub-dependencies (libjpeg, etc.)
- Apple ImageIO backend disabled: the build uses vendored decoders instead
- JPEG XL support disabled
- After the clone step, `./external/download.sh` runs to fetch the vendored sources

Depends on: SDL2

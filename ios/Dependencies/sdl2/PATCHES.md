# SDL2 — Patches & Build Notes

## Source

- **Upstream**: SDL 2.28.1
- **Fork**: <https://github.com/mkxp-z/SDL> branch `mkxp-z-2.28.1`
- **Base commit**: `4761467b2` ("Updated to version 2.28.1 for release")

## Patches

Three custom commits on top of upstream SDL 2.28.1:

1. **`07550ddbf`** (Struma) — Remove `-mwindows` linker flag
2. **`5042c1559`** (Struma) — Disable NEON, fix loading ANGLE on macOS
3. **`d3ac4c374`** (Splendide Imaginarius) — Disable NEON in `SDL_stretch.c`

The NEON patches prevent build/runtime issues on ARM platforms where the
NEON intrinsics cause problems with the cross-compilation toolchain.

## iOS Build Instructions

Built with CMake (out-of-tree in `cmakebuild/`):

```
cmake .. \
  -DBUILD_SHARED_LIBS=no \
  -DSDL_OPENGL=OFF \
  -DSDL_OPENGLES=ON \
  -DSDL_METAL=ON \
  -DSDL_RENDER_METAL=ON \
  <common CMAKE_ARGS from common.make>
```

Key flags:

- Desktop OpenGL disabled (`SDL_OPENGL=OFF`)
- OpenGL ES enabled (`SDL_OPENGLES=ON`) — the rendering backend used by mkxp-z on iOS
- Metal enabled for SDL's internal use

Common cross-compilation flags are inherited from `common.make` (sysroot,
architecture, deployment target, etc.).

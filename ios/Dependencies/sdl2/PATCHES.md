# SDL2: patches and build notes

## Source

- **Upstream**: SDL 2.28.1
- **Fork**: <https://github.com/mkxp-z/SDL> branch `mkxp-z-2.28.1`
- **Base commit**: `4761467b2` ("Updated to version 2.28.1 for release")

## Patches in mkxp-z/SDL (submodule)

Three custom commits on top of upstream SDL 2.28.1:

1. **`07550ddbf`** (Struma): Remove `-mwindows` linker flag
2. **`5042c1559`** (Struma): Disable NEON, fix loading ANGLE on macOS
3. **`d3ac4c374`** (Splendide Imaginarius): Disable NEON in `SDL_stretch.c`

The NEON patches prevent build and runtime issues on ARM platforms
where the NEON intrinsics cause problems with the cross-compilation
toolchain.

## Empo-local patches (applied at build time)

Empo keeps the SDL submodule pinned to the published `mkxp-z-2.28.1`
tip. It applies additional iOS fixes from `ios/Dependencies/sdl2/` via
`sdl2.patches.lst` + `apply-sdl-patches.sh` (the same model as Ruby).

**`empo-ios.patch`** - iOS runtime fixes on top of the fork tip:

- Defer renderbuffer resize to the GL-owning thread (rotation crash)
- Synchronous present to prevent SIGSEGV during rapid rotation
- Detect a broken GL context and bail out cleanly
- Create UIKit windows from the active `UIWindowScene`. The UIScene
  lifecycle on the iOS 27 SDK requires this, because iOS does not
  display legacy `initWithFrame:` windows.
- Keep the view frame the host set when the keyboard shows or hides,
  after the host moves SDL's view into its own window

The first three change `SDL_uikitopengles.m` and
`SDL_uikitopenglview.m`. Those files do not compile while
`SDL_OPENGLES` is OFF, so the three fixes do nothing now. They stay in
the patch for a build that turns GL ES on again.

After you edit the SDL submodule, regenerate the patch:

```sh
cd ios/Dependencies/sources/sdl2
git diff origin/mkxp-z-2.28.1..HEAD > ../sdl2/empo-ios.patch
```

## iOS build instructions

The build uses CMake (out-of-tree in `cmakebuild/`):

```
cmake .. \
  -DBUILD_SHARED_LIBS=no \
  -DSDL_OPENGL=OFF \
  -DSDL_OPENGLES=OFF \
  -DSDL_METAL=ON \
  -DSDL_RENDER_METAL=ON \
  <common CMAKE_ARGS from common.make>
```

Key flags:

- Desktop OpenGL disabled (`SDL_OPENGL=OFF`)
- OpenGL ES disabled (`SDL_OPENGLES=OFF`): mkxp-z drives ANGLE through
  EGL itself and never asks SDL for a GL context. With it ON,
  `SDL_uikitopenglview` linked in and pulled `EAGLContext`,
  `CAEAGLLayer` and four OES entry points with it, which forced
  `-weak_framework OpenGLES` on the MkxpCore link.
- Metal enabled for SDL's internal use

The build inherits common cross-compilation flags from `common.make`
(sysroot, architecture, deployment target, etc.).

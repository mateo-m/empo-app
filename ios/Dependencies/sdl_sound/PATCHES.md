# SDL_sound: Patches & Build Notes

## Source

- **Upstream**: SDL_sound 2.0.1
- **Fork**: <https://github.com/mkxp-z/SDL_sound> branch `git`
- **Base commit**: `506b9f0` ("version: Bumping version to 2.0.1 for actual release.")

## Patches

One custom commit on top of upstream:

1. **`cfb2533`** (Struma): Build properly on macOS
   - Fixes a build issue specific to macOS/Darwin toolchains.

## iOS build instructions

Built with CMake (out-of-tree in `cmakebuild/`):

```
cmake .. \
  -DSDLSOUND_BUILD_SHARED=false \
  -DSDLSOUND_BUILD_TEST=false \
  -DSDLSOUND_DECODER_COREAUDIO=false \
  <common CMAKE_ARGS from common.make>
```

Key flags:

- CoreAudio decoder disabled: uses Vorbis/Ogg decoders instead
- Test programs disabled

Depends on: SDL2, libogg, libvorbis

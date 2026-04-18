# Empo

Runs RPG Maker games on iOS.
It's a port of [mkxp-z](https://github.com/mkxp-z/mkxp-z) wrapped in a SwiftUI library and a touch-controls overlay.

## Status

Pre-release.
Not on the App Store.
Works end-to-end but there are rough edges (e.g. multi-gamesessions lifecycle, see `docs/multi-session.md`).

## What works

- Importing games (folders, zip, 7z, rar).
- Browsing them in a library.
- Playing them with a customizable on-screen D-pad and buttons.
- Pause, resume, switch games (see `docs/multi-session.md`).

## What doesn't

- Only RGSS1 (XP) and RGSS2 (VX). RGSS3 (VX Ace) is gated because we still link Ruby 1.8; MV/MZ are JavaScript and out of scope.
- Only Ogg/Theora movies. MP4 etc. are skipped.
- Games that lean hard on native Windows DLLs beyond what `win32_wrap.rb` emulates (e.g. Vinemon).
- Rotating the iOS Simulator during gameplay crashes inside Apple's GL emulation layer. Not reproducible on real devices. See `docs/rotation-crash.md`.

## Architecture

```
mkxp-z-apple-mobile/   engine fork, git submodule, pure C++
ios/Empo/              the app (SwiftUI + a bit of UIKit for touch controls)
ios/Dependencies/      cross-compiled static libs (SDL, Ruby 1.8, OpenAL, etc.)
docs/                  deep dives on the trickier bits
```

The engine doesn't know the app exists and the app doesn't include any engine headers. Everything goes through `mkxp-z-apple-mobile/src/app_bridge.h`, a tiny C API.
If you're adding a feature that needs to cross that boundary, add a bridge function.

## Quirks & hacks

**One process, many games.** iOS doesn't let apps terminate and relaunch themselves between games, so SDL, the GL context, OpenAL, and the Ruby VM are created once and reused. Between sessions we manually evict game-defined Ruby constants, detach RGSS disposables, and re-run our preload patches. See `docs/multi-session.md` and `docs/sdl-ruby-workarounds.md`.

**Ruby 1.8, not 3.1.** Most XP games break on Ruby 3 syntax. We cross-compile 1.8 from [JoiPlay's fork](https://github.com/joiplay/ruby).
Moving to 3.1 might be possible with the `syntaxTransform` flag that [this PR](https://github.com/mkxp-z/mkxp-z/pull/304) might introduce to upstream [mkxp-z](https://github.com/mkxp-z/mkxp-z), if it gets merged.

**Win32 emulation is mostly `.rb` files.** `win32_wrap.rb` (CC0, by Ancurio and Splendide Imaginarius) plus our `platform_compat.rb` stub out the Windows APIs games expect, neutralize `system`/`fork`/`spawn` so games can't launch new processes, and silently swallow load errors from encrypted archives. They live under `mkxp-z-apple-mobile/scripts/`.

**Pause uses a frozen screenshot.** SDL's window can't participate in SwiftUI transitions, so we `glReadPixels` the last frame, hand the bytes to Swift, display the image at the engine's game rect through the hero zoom, and fade it out once the live surface is back. `docs/pause-resume.md`.

**Touch controls talk to the engine through SDL events.** The overlay calls `SDL_PushEvent` with synthetic key events so the engine sees them exactly as if they came from a keyboard. No engine changes needed for new buttons or layouts.

**`GitInfo.generated.swift` is auto-generated** by a `.githooks/post-commit` hook that `setup.sh` installs. The file is gitignored; it just embeds the current commit hash for the Settings screen.

## Building

You need Xcode with the iOS 26+ SDK, `brew install xcodegen`, the usual autotools (`autoconf automake libtool cmake pkg-config`), and an Apple developer account.

```sh
git clone --recursive git@github.com:mateo-m/empo-app.git
cd empo-app

# Point git at the tracked hooks and write an initial GitInfo.generated.swift
# so Xcode has something to compile before your first commit.
./setup.sh

# Build third-party deps (slow first time, cached after)
make -C ios/Dependencies -f iphonesimulator.make deps-core

# Generate the Xcode project and build the app
xcodegen generate --spec ios/Empo/project.yml --project ios/Empo
xcodebuild -project ios/Empo/Empo.xcodeproj -target Empo \
  -sdk iphonesimulator -arch arm64 -configuration Debug build

# Install on a booted simulator
SIM=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
xcrun simctl install "$SIM" ios/Empo/build/Debug-iphonesimulator/Empo.app
xcrun simctl launch "$SIM" sh.mateo.empo
```

Swap `iphonesimulator` for `iphoneos` for on-device. You'll need a gitignored `ios/Empo/Signing.xcconfig` with your `DEVELOPMENT_TEAM`.

## License

GPLv2, matching upstream [mkxp-z](https://github.com/mkxp-z/mkxp-z).
Full dependency and font licenses are surfaced in the app at Settings → Open-source licenses.

## Credits

- [Ancurio](https://github.com/Ancurio) for the original [mkxp](https://github.com/Ancurio/mkxp).
- The [mkxp-z contributors](https://github.com/mkxp-z/mkxp-z/graphs/contributors) for keeping it alive.
- [JoiPlay](https://github.com/joiplay) for [the Ruby 1.8 cross-compilation work](https://github.com/joiplay/ruby).

# Empo

Runs RPG Maker games on iOS.
It's a port of [mkxp-z](https://github.com/mkxp-z/mkxp-z) wrapped in a SwiftUI library and a touch-controls overlay.

## Status

Pre-release.
Not on the App Store.
Works end-to-end across RGSS1/2/3 and modern mkxp-z-based forks.

## What works

- Importing games (folders, zip, 7z, rar).
- Browsing them in a library.
- Playing them with a customizable on-screen D-pad and buttons.
- Multi-Ruby native dispatch: vintage XP games run on Ruby 1.8.7, VX/VX Ace on 1.9.2, PSDK on 3.0, modern mkxp-z forks on 3.1. See `docs/multi-ruby.md`.
- Pause, resume (`docs/pause-resume.md`).

## What doesn't

- Switching between different games in one session (cross-session play). After a clean game exit the user is asked to close + reopen Empo from the app switcher; Ruby state cleanup across different scripts is parked behind a feature flag.
- Only Ogg/Theora movies. MP4 etc. are skipped.
- Games that lean hard on native Windows DLLs beyond what `win32_wrap.rb` emulates.
- Rotating the iOS Simulator during gameplay crashes inside Apple's GL emulation layer. Not reproducible on real devices.

## Architecture

```
mkxp-z-apple-mobile/   engine fork, git submodule, pure C++
ios/Empo/              the app (SwiftUI + a bit of UIKit for touch controls)
ios/Dependencies/      cross-compiled static libs (SDL, four Ruby versions, OpenAL, etc.)
docs/                  deep dives on the trickier bits
```

The engine doesn't know the app exists and the app doesn't include any engine headers. Everything goes through `mkxp-z-apple-mobile/src/app_bridge.h`, a tiny C API.
If you're adding a feature that needs to cross that boundary, add a bridge function.

## Quirks & hacks

**One process, many Rubys.** Empo links four Ruby interpreters (1.8.7, 1.9.2, 3.0, 3.1) into one binary as per-version merged `.o` files with hidden symbol islanding via `ld -r --unexported_symbols_list`. At launch time the host detects which Ruby a game wants and dispatches through `mkxp_get_script_binding_NN`. See `docs/multi-ruby.md`.

**Persistent SDL + Ruby VM.** iOS doesn't let apps terminate and relaunch themselves between games, so SDL, the GL context, OpenAL, and the active Ruby VM are created once and reused for the process lifetime. Cross-session play (switching to a different game without force-closing) is currently disabled - the active Ruby's loaded constants leak across game scripts and cause superclass-mismatch chaos. See `docs/sdl-ruby-workarounds.md`.

**Syntax transform for Ruby 3.1 only.** Some Pokemon Essentials forks (Vinemon, etc.) mix Ruby 1.8 syntax with Ruby 1.9+ runtime methods - they can't run on 1.8 native (no `force_encoding`) or vanilla 3.1 (parser rejects `when X:`). The 3.1 binding ships [PR #304's syntax-transform patches](https://github.com/mkxp-z/mkxp-z/pull/304) that teach Ruby 3.1's parser to accept legacy grammar; activated per-game via the bridge. See `docs/ruby31-experiment.md`.

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
- [JoiPlay](https://github.com/joiplay) for [the Ruby 1.8 cross-compilation work](https://github.com/joiplay/ruby) and the multi-Ruby dispatch model their RPG Maker plugin uses.
- [white-axe](https://github.com/white-axe) for [PR #304](https://github.com/mkxp-z/mkxp-z/pull/304) (the Ruby 3.1 syntax-transform patches).

# Empo

> Run RPG Maker games on iPhone and iPad.

[![License](https://img.shields.io/badge/license-GPLv2%2B-blue.svg)](#license)
[![Status](https://img.shields.io/badge/status-pre--release-yellow.svg)](#status)
[![Platform](https://img.shields.io/badge/platform-iOS%2026%2B-lightgrey.svg)](#requirements)

Empo wraps the [mkxp-z](https://github.com/mkxp-z/mkxp-z) RPG Maker engine in a native SwiftUI library and a customizable touch-controls overlay. Vintage RPG Maker XP / VX / VX Ace games and modern Pokemon Essentials forks all run on-device, no desktop emulator needed.

## Table of Contents

- [Highlights](#highlights)
- [Status](#status)
- [How it works](#how-it-works)
- [Notable hacks](#notable-hacks)
- [Requirements](#requirements)
- [Build](#build)
- [Importing games](#importing-games)
- [Contributing](#contributing)
- [License](#license)
- [Credits](#credits)

## Highlights

- Plays games made for RGSS1 (XP), RGSS2 (VX), RGSS3 (VX Ace), and the modern mkxp-z fork ecosystem (Reborn, Vanguard, Flux, Insurgence, Infinite Fusion, etc.).
- **Multi-Ruby native dispatch.** Four Ruby interpreters (1.8, 1.9, 3.0, 3.1) share one binary; each game runs on the actual Ruby version it was authored against. See [`docs/multi-ruby.md`](docs/multi-ruby.md).
- Imports games from folders, `.zip`, `.7z`, `.rar`, and JoiPlay's `.jgp` format.
- Customizable on-screen D-pad and action buttons, with per-game layouts.
- Pause and resume from the library; a frozen-frame snapshot bridges SDL into the SwiftUI hero zoom transition.
- Library with sort, search, grid/list views, and bulk delete.

## Status

Pre-release. Not on the App Store.

End-to-end working across the RGSS1/2/3 and modern mkxp-z fork landscape. Compatibility reports for individual games are welcome (open an issue).

### Limitations

- **Single game per session.** After exiting a game, force-close + reopen Empo from the app switcher to start a different one. Cross-session play is parked pending reliable Ruby state cleanup; see [`docs/multi-session.md`](docs/multi-session.md).
- **Ogg/Theora movies only.** MP4 and other formats are skipped silently.
- **Native Windows DLL dependencies.** Games leaning on Win32 APIs beyond what the engine's `win32_wrap.rb` emulates may fail to load some assets.
- **Simulator rotation.** Rotating the iOS Simulator during gameplay crashes inside Apple's GL emulation layer. Real devices are fine.

## How it works

```
mkxp-z-apple-mobile/   Engine fork (git submodule, pure C++)
ios/Empo/              The app (SwiftUI + UIKit for touch controls)
ios/Dependencies/      Cross-compiled static libs (SDL, four Ruby versions, OpenAL, etc.)
docs/                  Deep dives on the trickier bits
```

The engine doesn't know the app exists and the app doesn't include any engine headers. Everything crosses through [`mkxp-z-apple-mobile/src/app_bridge.h`](mkxp-z-apple-mobile/src/app_bridge.h), a small C ABI.

For deeper architectural context:

| Doc | What it covers |
|---|---|
| [`docs/multi-ruby.md`](docs/multi-ruby.md) | How four Ruby interpreters live in one binary, and how the right one gets picked per game. |
| [`docs/sdl-ruby-workarounds.md`](docs/sdl-ruby-workarounds.md) | Why SDL, the GL context, OpenAL, and the active Ruby VM are persistent for the process lifetime. |
| [`docs/pause-resume.md`](docs/pause-resume.md) | Frozen-frame snapshots that bridge the SDL window into SwiftUI transitions. |
| [`docs/multi-session.md`](docs/multi-session.md) | Why cross-session play is currently disabled. |

## Notable hacks

A few load-bearing tricks worth flagging if you're poking around:

- **Persistent SDL + Ruby VM.** SDL, the GL context, OpenAL, and the active Ruby interpreter are created once and reused for the process lifetime. iOS doesn't let apps relaunch themselves between games, and CRuby's `ruby_init()` is one-shot per process.
- **Per-version merged `.o` for Ruby.** Each Ruby version's libruby + binding compile separately, then `ld -r --unexported_symbols_list` hides every Ruby internal so all four versions can coexist in one binary. Each `.o` exports exactly one global: `_mkxp_get_script_binding_NN`.
- **Syntax transform on Ruby 3.1 only.** Mixed-grammar Pokemon Essentials forks (Vinemon, Sauce Edition, etc.) combine 1.8 syntax with 1.9+ runtime methods. They can't run on 1.8 native (no `force_encoding`) or vanilla 3.1 (parser rejects `when X:`). The 3.1 binding ships [PR #304's syntax-transform patches](https://github.com/mkxp-z/mkxp-z/pull/304); the host activates LEGACY mode per game.
- **Win32 emulation in Ruby.** [`win32_wrap.rb`](mkxp-z-apple-mobile/scripts/preload/win32_wrap.rb) (CC0, by Ancurio and Splendide Imaginarius) plus [`platform_compat.rb`](mkxp-z-apple-mobile/scripts/preload/platform_compat.rb) stub out the Windows APIs games expect, neutralize `system`/`fork`/`spawn` so games can't launch new processes, and swallow load errors from encrypted archives.
- **Touch controls via SDL events.** The overlay calls `SDL_PushEvent` with synthetic key events, so the engine sees them exactly as if they came from a hardware keyboard. New buttons or layouts need no engine changes.

## Requirements

- macOS with Xcode 26 or newer (iOS 26 SDK).
- Homebrew (`xcodegen`, `autoconf`, `automake`, `libtool`, `cmake`, `pkg-config`).
- Apple developer account (only required for on-device builds).
- iPhone or iPad running iOS 26+ for on-device testing. iPhone 11 is the floor model.

## Build

```sh
# Tools
brew install xcodegen autoconf automake libtool cmake pkg-config

# Repo (recursive for submodules)
git clone --recursive git@github.com:mateo-m/empo-app.git
cd empo-app

# Wire up the tracked git hooks and seed an initial
# GitInfo.generated.swift so Xcode has something to compile before
# your first local commit.
./setup.sh

# Cross-compile third-party deps. Slow on first run, cached after.
make -C ios/Dependencies -f iphonesimulator.make deps-core

# Generate the Xcode project and build the app
xcodegen generate --spec ios/Empo/project.yml --project ios/Empo
xcodebuild -project ios/Empo/Empo.xcodeproj -target Empo \
  -sdk iphonesimulator -arch arm64 -configuration Debug build
```

Install on a booted simulator:

```sh
SIM=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
xcrun simctl install "$SIM" ios/Empo/build/Debug-iphonesimulator/Empo.app
xcrun simctl launch "$SIM" sh.mateo.empo
```

For device builds, swap `iphonesimulator` for `iphoneos` and create a gitignored `ios/Empo/Signing.xcconfig` with your `DEVELOPMENT_TEAM`.

## Importing games

Empo accepts a few different shapes:

- A folder containing a vanilla RPG Maker `Game.exe` + `Data/` layout.
- A `.zip`, `.7z`, or `.rar` archive containing the same.
- A `.jgp` (JoiPlay Game Package) manifest pointing at game files.

Drag any of these onto the Empo icon, share them from another app, or use the Files picker from the library's import button. Empo identifies the engine version, picks the right Ruby interpreter, extracts artwork from `Game.exe` if present, and writes everything to its sandbox so the original imported folder stays pristine.

## Contributing

Issues, ideas, and PRs welcome.

**Especially helpful:**

- Game compatibility reports. If a game crashes or renders wrong, open an issue with the title, version, and a description of what went wrong. Logs from Settings → Diagnostics are gold.
- Touch-control layout suggestions for games that don't fit the default layout well.
- Engine bridge contributions; if you need the host to expose new state, open an issue first to talk through the API.

**When opening a PR:**

- Match the existing code style. No formatter is enforced; imitate nearby code.
- Build green on the iOS Simulator before requesting review.
- Reference any related issue.

## License

[GPLv2+](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html), matching upstream [mkxp-z](https://github.com/mkxp-z/mkxp-z). The full dependency and font license set is surfaced in the app at **Settings → Open-source licenses**.

## Credits

- [Ancurio](https://github.com/Ancurio) for the original [mkxp](https://github.com/Ancurio/mkxp) engine.
- The [mkxp-z contributors](https://github.com/mkxp-z/mkxp-z/graphs/contributors) for keeping it alive on desktop.
- [JoiPlay](https://github.com/joiplay) for the [Ruby 1.8 cross-compilation work](https://github.com/joiplay/ruby) and the multi-Ruby dispatch model their RPG Maker plugin uses.
- [white-axe](https://github.com/white-axe) for [PR #304](https://github.com/mkxp-z/mkxp-z/pull/304), the Ruby 3.1 syntax-transform patches that keep mixed-grammar Pokemon Essentials forks running.
- [MGC](https://www.save-point.org/thread-3151.html) for the original H-Mode7 RPG Maker XP plugin (the pseudo-3D renderer behind Pokemon Insurgence's flying intro). Our [native port](mkxp-z-apple-mobile/hmode7) re-implements it on mkxp-z's `Bitmap` and `Table` APIs.
- [Splendide Imaginarius](https://github.com/Splendide-Imaginarius) for the `win32_wrap.rb` extensions that keep Windows-only RPG Maker games loading on non-Windows targets.

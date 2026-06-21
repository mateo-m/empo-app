<p align="center"><a href="https://discord.gg/m3YnpXMxrB"><img src="docs/media/empo-icon.png" alt="Empo icon" width="160" /></a></p>

# <p align="center"><a href="https://discord.gg/m3YnpXMxrB">Empo</a></p>

> <p align="center">Run RPG Maker games on iPhone and iPad.</p>

<p align="center">
  <a href="#license"><img alt="License" src="https://img.shields.io/badge/license-GPLv2%2B-blue.svg" /></a>
  <a href="#status"><img alt="Status" src="https://img.shields.io/badge/status-pre--release-yellow.svg" /></a>
  <a href="#requirements"><img alt="Platform" src="https://img.shields.io/badge/platform-iOS%2026%2B-lightgrey.svg" /></a>
</p>

<p align="center"><a href="https://discord.gg/m3YnpXMxrB">Discord</a></p>

Empo wraps the [mkxp-z](https://github.com/mkxp-z/mkxp-z) RPG Maker engine in a native SwiftUI library and a customizable touch-controls overlay. RPG Maker XP / VX / VX Ace games and modern Pokemon Essentials forks run on-device, no desktop emulator needed.

The name's from _emporos_, ancient Greek for a traveler riding on someone else's ship.

## Demo

Import a game and play it:

https://github.com/user-attachments/assets/d19e44ff-c2ef-435f-b2fe-60f1c97890c8

Library view:

https://github.com/user-attachments/assets/1a6de8a7-b47c-4ad4-8df9-f028347dfb9c

In-game battle:

|                  Cinematic                  |                Battle                 |                  Overworld                  |
| :-----------------------------------------: | :-----------------------------------: | :-----------------------------------------: |
| ![Cinematic](docs/media/demo-cinematic.png) | ![Battle](docs/media/demo-battle.png) | ![Overworld](docs/media/demo-overworld.png) |

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

- Plays games made for RGSS1 (XP), RGSS2 (VX), RGSS3 (VX Ace), and modern mkxp-z forks.
- **Multi-Ruby native dispatch.** Three Ruby interpreters (1.8, 1.9, 3.1) ship in one binary; each game runs on the Ruby version it was authored against. Modern Pokemon Essentials forks shipping a `ruby300.dll` route to 3.1 with the syntax-transform compatibility mode. See [`docs/multi-ruby.md`](docs/multi-ruby.md).
- Imports games from folders, `.zip`, `.7z`, `.rar`, and JoiPlay's `.jgp` format.
- Customizable on-screen D-pad and action buttons, with per-game layouts.
- Pause and resume from the library; a frozen-frame snapshot bridges SDL into the SwiftUI hero zoom transition.
- Library with sort, search, grid/list views, and bulk delete.

## Status

Pre-release. Not on the App Store.

End-to-end working across RGSS1/2/3 games and modern mkxp-z forks. Per-game compatibility reports are welcome (open an issue).

Pre-built unsigned `.ipa` files are attached to each tagged release on the [Releases page](https://github.com/mateo-m/empo-app/releases). Install with [AltStore](https://altstore.io), [Sideloadly](https://sideloadly.io), or sign yourself if you have an Apple Developer account.

AltStore / SideStore users can add Empo as a source for native update notifications:

```text
https://raw.githubusercontent.com/mateo-m/empo-app/main/altstore-source.json
```

`altstore-source.json` is updated by `scripts/release.sh` and committed to `main` as part of the local signed release flow. If you ever need to re-sync it after manually editing a GitHub release, run `bun scripts/update-altstore-source.ts ...` locally and commit the manifest update with your normal signing key.

### Limitations

- **Single game per session.** After exiting a game, force-close + reopen Empo from the app switcher to start a different one. Cross-session play is parked pending reliable Ruby state cleanup; see [`docs/multi-session.md`](docs/multi-session.md).
- **Ogg/Theora movies only.** MP4 and other formats are skipped silently.
- **Native Windows DLL dependencies.** Games leaning on Win32 APIs beyond what the engine's `win32_wrap.rb` emulates may fail to load some assets.

## How it works

```text
mkxp-z-apple-mobile/   Engine fork (git submodule, pure C++)
ios/Empo/              The app (SwiftUI + UIKit for touch controls)
ios/Dependencies/      Cross-compiled static libs (SDL, four Ruby versions, OpenAL, etc.)
docs/                  Deep dives on the trickier bits
```

The engine doesn't know the app exists and the app doesn't include any engine headers. Everything crosses through [`mkxp-z-apple-mobile/src/app_bridge.h`](mkxp-z-apple-mobile/src/app_bridge.h), a small C ABI.

For deeper architectural context:

| Doc                                                            | What it covers                                                                                   |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| [`docs/multi-ruby.md`](docs/multi-ruby.md)                     | How four Ruby interpreters live in one binary, and how the right one gets picked per game.       |
| [`docs/sdl-ruby-workarounds.md`](docs/sdl-ruby-workarounds.md) | Why SDL, the GL context, OpenAL, and the active Ruby VM are persistent for the process lifetime. |
| [`docs/pause-resume.md`](docs/pause-resume.md)                 | Frozen-frame snapshots that bridge the SDL window into SwiftUI transitions.                      |
| [`docs/multi-session.md`](docs/multi-session.md)               | Why cross-session play is currently disabled.                                                    |

## Notable hacks

A few load-bearing tricks worth flagging if you're poking around:

- **Multi-Ruby in one binary.** Four Ruby versions (1.8, 1.9, 3.0, 3.1) compile separately, then each version's libruby + binding code merges into a single relocatable `.o` with hidden symbol islanding via `ld -r --unexported_symbols_list`. Each `.o` exports exactly one global, `_mkxp_get_script_binding_NN`. The host calls `mkxp_setActiveRubyVersion()` per game and the engine dispatches accordingly. See [`docs/multi-ruby.md`](docs/multi-ruby.md).
- **Persistent SDL + Ruby VM.** SDL, the GL context, OpenAL, and the active Ruby interpreter are created once and reused for the process lifetime. iOS doesn't let apps relaunch themselves between games, and CRuby's `ruby_init()` is one-shot per process.
- **Syntax-transform patches on Ruby 3.1.** The Ruby 3.1 build also applies [PR #304's parser patches](https://github.com/mkxp-z/mkxp-z/pull/304) so mixed-grammar Pokemon Essentials forks (1.8 syntax + 1.9+ runtime methods) parse on Ruby 3.1's VM. The host activates LEGACY mode per game where needed; otherwise vanilla 3.1 parsing applies.
- **Win32 emulation in Ruby.** [`win32_wrap.rb`](mkxp-z-apple-mobile/scripts/preload/win32_wrap.rb) (CC0, by Ancurio and Splendide Imaginarius) plus [`platform_compat.rb`](mkxp-z-apple-mobile/scripts/preload/platform_compat.rb) stub out the Windows APIs games expect, neutralize `system`/`fork`/`spawn` so games can't launch new processes, and swallow load errors from encrypted archives.
- **Touch controls via SDL events.** The overlay calls `SDL_PushEvent` with synthetic key events, so the engine sees them exactly as if they came from a hardware keyboard. New buttons or layouts need no engine changes.

## Requirements

- macOS with Xcode 26 or newer (iOS 26 SDK).
- Homebrew (`xcodegen`, `autoconf`, `automake`, `libtool`, `cmake`, `pkg-config`).
- Apple developer account (only required for on-device builds).
- iPhone or iPad running iOS 26+ for on-device testing. iPhone 11 is the floor model.

## Build

Native libraries (OpenSSL, SDL, Ruby, mkxp-merged) ship as **prebuilt trees per SDK**, same model as ANGLE. After cloning:

```sh
brew install bun xcodegen gh autoconf automake libtool cmake pkg-config
git clone --recursive git@github.com:mateo-m/empo-app.git
cd empo-app
bun install

# Hydrate ANGLE + native deps (downloads from empo-deps when published,
# or uses locally-built trees — see below)
xcodegen generate --spec ios/Empo/project.yml --project ios/Empo
xcodebuild -project ios/Empo/Empo.xcodeproj -target Empo \
  -sdk iphonesimulator -arch arm64 -configuration Debug build
```

### First-time / dep-bump setup

When `ios/Dependencies/native/.version` is still `unpublished`, or you changed a dependency version, build **both** SDK trees once (sequential — do not `make -j` everything):

```sh
scripts/rebuild-all-native-deps.sh
tools/package-native-deps.sh native-$(date +%Y-%m-%d)
# upload tarball to empo-deps, commit ios/Dependencies/native/.version
```

Verify a single tree:

```sh
PLATFORM_NAME=iphoneos scripts/verify-native-deps.sh
PLATFORM_NAME=iphonesimulator scripts/verify-native-deps.sh
```

### Simulator install

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

- Run `bun install` once after cloning so LeftHook installs the empo-app hooks.
- If you will commit inside `mkxp-z-apple-mobile`, also run `(cd mkxp-z-apple-mobile && bun install)`.
- Formatting and linting are enforced locally by LeftHook and again in CI.
- Build green on the iOS Simulator before requesting review.
- Reference any related issue.

## License

[GPLv2+](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html), matching upstream [mkxp-z](https://github.com/mkxp-z/mkxp-z). The full dependency and font license set is surfaced in the app at **Settings → Open-source licenses**.

## Credits

- [Ancurio](https://github.com/Ancurio) for the original [mkxp](https://github.com/Ancurio/mkxp) engine.
- The [mkxp-z contributors](https://github.com/mkxp-z/mkxp-z/graphs/contributors) for keeping it alive on desktop.
- [JoiPlay](https://github.com/joiplay) for the [Ruby 1.8 cross-compilation work](https://github.com/joiplay/ruby) and the multi-Ruby dispatch model their RPG Maker plugin uses.
- [white-axe](https://github.com/white-axe) for [PR #304](https://github.com/mkxp-z/mkxp-z/pull/304), the Ruby 3.1 syntax-transform patches that mkxp-z-apple-mobile applies to its 3.1 build.
- [MGC](https://www.save-point.org/thread-3151.html) for the original H-Mode7 RPG Maker XP plugin. The [native port](mkxp-z-apple-mobile/hmode7) re-implements it on mkxp-z's `Bitmap` and `Table` APIs.
- [Splendide Imaginarius](https://github.com/Splendide-Imaginarius) for the `win32_wrap.rb` extensions that keep Windows-only RPG Maker games loading on non-Windows targets.

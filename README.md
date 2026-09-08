<p align="center"><a href="https://discord.gg/m3YnpXMxrB"><img src="docs/media/empo-icon.png" alt="Empo icon" width="160" /></a></p>

# <p align="center"><a href="https://discord.gg/m3YnpXMxrB">Empo</a></p>

> <p align="center">Run RPG Maker games on iPhone and iPad.</p>

<p align="center">
  <a href="#license"><img alt="License" src="https://img.shields.io/badge/license-GPLv2%2B-blue.svg" /></a>
  <a href="#status"><img alt="Status" src="https://img.shields.io/badge/status-pre--release-yellow.svg" /></a>
  <a href="#requirements"><img alt="Platform" src="https://img.shields.io/badge/platform-iOS%2026%2B-lightgrey.svg" /></a>
</p>

<p align="center"><a href="https://discord.gg/m3YnpXMxrB">Discord</a></p>

Empo is a game launcher for iPhone and iPad. It runs RPG Maker XP, VX, and VX Ace games, and Pokemon Essentials games. Inside, it uses [mkxp-z-apple-mobile](https://github.com/mateo-m/mkxp-z-apple-mobile), an iOS fork of the [mkxp-z](https://github.com/mkxp-z/mkxp-z) engine.

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

## Table of contents

- [Highlights](#highlights)
- [Status](#status)
- [How it works](#how-it-works)
- [Importing games](#importing-games)
- [Contributing](#contributing)
- [License](#license)
- [Credits](#credits)

## Highlights

- Plays games made for RGSS1 (XP), RGSS2 (VX), RGSS3 (VX Ace), and modern mkxp-z forks.
- **Three Ruby versions in one app.** Empo includes Ruby 1.8, 1.9, and 3.1. Each game runs on the version it was written for. Newer Pokemon Essentials games that ship a `ruby300.dll` run on Ruby 3.1, and Empo rewrites their older syntax as needed. See [`ios/Empo/docs/multi-ruby.md`](ios/Empo/docs/multi-ruby.md).
- Imports games from folders or archives (`.zip`, `.7z`, `.rar`, JoiPlay's `.jgp`, self-extractable `.exe`).
- On-screen D-pad and action buttons you can move and resize. Layouts can differ per game and per screen orientation.
- Pause and resume from the library.
- Library with sort, search, grid/list views, and bulk delete.

## Status

Pre-release. Not on the App Store.

The app works end to end with RGSS1/2/3 games and modern mkxp-z forks. Per-game compatibility reports are welcome (open an issue).

Each tagged release on the [Releases page](https://github.com/mateo-m/empo-app/releases) includes pre-built unsigned `.ipa` files. Install them with [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or [Sideloadly](https://sideloadly.io).

AltStore/SideStore users can add Empo as a source for native update notifications:

```text
https://raw.githubusercontent.com/mateo-m/empo-app/main/altstore-source.json
```

### Limitations

- **One game per session.** After you exit a game, close Empo from the app switcher and reopen it to start a different one. This limit stays until Ruby can clear its state reliably. See [`ios/Empo/docs/multi-session.md`](ios/Empo/docs/multi-session.md).
- **Ogg and Theora movies only.** The engine skips MP4 and other formats without a message.
- **Windows-only code.** Some games call Windows functions that the engine's `win32_wrap.rb` does not copy. Those games can fail to load some files.

## How it works

```text
mkxp-z-apple-mobile/   Engine fork (git submodule, pure C++)
ios/Empo/              The app (SwiftUI + UIKit for touch controls)
ios/Dependencies/      Cross-compiled static libs (SDL, three Ruby versions, OpenAL, etc.)
docs/                  Notes on the harder parts
```

The [documentation site](https://empo.mateo.sh/) covers the rest: how to
install and play, what game developers can ship with a game, and how the harder parts of the
app work. The source is in [`docs/`](docs/README.md). To read it in a browser locally, run:

```sh
bun install
bun run docs:dev
```

## Importing games

Empo accepts these input shapes:

- A folder with a standard RPG Maker `Game.exe` and `Data/` layout.
- A `.zip`, `.7z`, or `.rar` archive with the same content.
- A `.jgp` (JoiPlay Game Package) manifest that points at game files.

Drag any of these onto the Empo icon, share them from another app, or use the Files picker from the library's import button. Empo identifies the engine version, picks the correct Ruby interpreter, and extracts artwork from `Game.exe` if present. Empo writes everything to its sandbox, so the original imported folder stays unchanged.

## Contributing

Issues, ideas, and PRs are welcome. Game compatibility reports help the most: open an issue with the game title, the game version, and a description of what went wrong.

For build requirements, build steps, and PR guidelines, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

[GPLv2+](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html), the same license as upstream [mkxp-z](https://github.com/mkxp-z/mkxp-z). The app shows the full dependency and font license set at **Settings → Open-source licenses**.

## Credits

- [Ancurio](https://github.com/Ancurio) for the original [mkxp](https://github.com/Ancurio/mkxp) engine.
- The [mkxp-z contributors](https://github.com/mkxp-z/mkxp-z/graphs/contributors) for keeping it alive on desktop.
- [JoiPlay](https://github.com/joiplay) for the [Ruby 1.8 cross-compilation work](https://github.com/joiplay/ruby) and the multi-Ruby dispatch model their RPG Maker plugin uses.
- [white-axe](https://github.com/white-axe) for [PR #304](https://github.com/mkxp-z/mkxp-z/pull/304), the Ruby 3.1 syntax-transform patches that mkxp-z-apple-mobile applies to its 3.1 build.
- [MGC](https://www.save-point.org/thread-3151.html) for the original H-Mode7 RPG Maker XP plugin. The [native port](mkxp-z-apple-mobile/hmode7) re-implements it on mkxp-z's `Bitmap` and `Table` APIs.
- [Splendide Imaginarius](https://github.com/Splendide-Imaginarius) for the `win32_wrap.rb` extensions that keep Windows-only RPG Maker games loading on non-Windows targets.

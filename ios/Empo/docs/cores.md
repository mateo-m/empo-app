---
title: Cores
description: What a game core is, what it must export, and the rules a launcher follows to open one.
---

## What a core is

A core is one dynamic framework that holds a whole game engine. It carries
its own Ruby, its own classes, its own SDL or SFML, and its own assets. Empo
has two:

- `MkxpCore.framework`: mkxp-z, with Ruby 1.8, 1.9 and 3.1, on SDL2.
- `PsdkCore.framework`: LiteRGSS2 and LiteCGSS, with Ruby 3.0, on SFML.

Both engines declare a class named `ViewportElement` at global scope, and both
carry a full Ruby. Linking both into one binary makes them share those names.
A dynamic framework with an export list does not. That is why a core is a
framework and not a static library.

## What a build ships

A build carries one core or both. `EMPO_CORES` in `ios/Empo/project.yml`
names the cores, and the "Embed the cores" phase copies those frameworks into
the app. Ship one core from the command line:

```sh
xcodebuild ... EMPO_CORES=PsdkCore
```

The app reads its own bundle to find what it got. `BuiltInGameCore` lists the
core frameworks that are there, the Game cores screen shows that list, and
`GameCoreKind.forGame` says which core a game folder needs. Empo refuses a game
whose core is absent in two places. The import stops and names the missing core,
and the library shows the same sentence when the player taps the card.

`GameImportValidator` answers a different question: are these files a game.
It must not ask which cores the build has. `GameCatalog` calls it on every scan
and can delete a container it calls invalid, and a missing core is not a broken
game.

`scripts/audit-ipa.sh` audits the cores it finds in the bundle. Pass
`--cores "MkxpCore PsdkCore"` to demand an exact set.

## What a core exports

A core exports its bridge and nothing else. `MkxpCore` exports the 102 `mkxp_*`
names that `mkxp-z-apple-mobile/src/app_bridge.h` declares. `PsdkCore` exports
the same 102 names under `psdk_*`, from
`ios/Dependencies/psdk/psdk_app_bridge.h`, plus the two `psdk_*` entry points in
`ios/Dependencies/psdk/psdk_core.h`.

No core exports a Ruby name, an SDL name or an SFML name, and no core imports
one either. `scripts/check-mkxp-framework.sh` and
`scripts/check-psdk-framework.sh` fail the build when that stops being true.
They also fail when a core leaves the two-level namespace, because a flat
namespace would let a second core bind to the first core's names.

## What a launcher setting means for each core

Empo sends both cores the same settings. Each core answers with what its
own engine has. The PSDK core answers four:

| Setting | What the PSDK core does |
| --- | --- |
| Fixed aspect ratio | `placeOutputRegion` fits the picture in the launcher's region and centres it. |
| Smooth scaling | The SFML fork reads the flag in the `sf::Texture` constructor, so every picture the game makes after that is smooth. The game's own resolution goes up to the screen with the GL viewport, so the filter of each texture decides how the whole picture looks. A texture reads the flag once, so a new value needs a restart. |
| Touch acts as mouse | LiteRGSS2 keeps the touch events out of the game while it is off. |
| Fast forward | `runtime_prelude.rb` multiplies the frame rate that `Graphics::FPSBalancer` reads. The balancer divides the real clock by that rate and runs that many game frames, so the game runs faster and still draws at the same rate. A new value applies while the game runs. |

The other rows belong to mkxp-z: render scale, frame skip, solid fonts,
postload scripts, the path cache, the in-game keyboard, JoiPlay
compatibility, the Ruby version and network access. `GameSettingsView`
shows a PSDK game only the rows above and the layout profile.

## What the engine asks the bridge

`psdk_app_bridge.cpp` answers two sets of names. The launcher interface
is the set in `psdk_app_bridge.h`. The other set is what the engine and
the SFML fork call, and no header declares it:

| Name | Who calls it |
| --- | --- |
| `psdk_game_resolution` | LiteRGSS2, with the resolution the game asked for |
| `psdk_frame_rendered` | the SFML fork, on every frame it swaps |
| `psdk_picture_rect_pixels` | LiteRGSS2, to put a touch inside the picture |
| `psdk_touch_mouse_enabled` | LiteRGSS2, before it sends a touch to the game |
| `psdk_smooth_scaling_enabled` | the SFML fork, in the `sf::Texture` constructor, and LiteRGSS2 for the window settings |
| `psdk_fast_forward_multiplier` | LiteRGSS2, for `LiteRGSS.fast_forward_multiplier` |

Each name is weak where the engine declares it, so both forks still build
without a launcher behind them. `check-core-interface.sh` reads the
header, so a name here never reaches the other two copies of the
interface.

## One interface, one prefix for each side

The same interface exists three times, once on each side, and each side owns
its prefix:

| Side | File | Prefix |
| --- | --- | --- |
| Empo | `ios/Empo/src/App/GameCore.h` | `gamecore_` |
| MkxpCore | `mkxp-z-apple-mobile/src/app_bridge.h` | `mkxp_` |
| PsdkCore | `ios/Dependencies/psdk/psdk_app_bridge.h` | `psdk_` |

Each core keeps the prefix its own project already used, so neither fork has to
follow the other. Empo names no engine in its own header, and its forwarder puts
the open core's prefix in front of the name at `dlsym` time.

The price is three copies to keep in step.
`scripts/check-core-interface.sh` strips the three prefixes and compares the
files, and fails when one of them drifts. Read it as the rule: a core that drops
a name or changes an argument makes Empo abort in the forwarder at run time.

## How a launcher opens a core

1. Open the framework binary with `dlopen(path, RTLD_NOW | RTLD_LOCAL)`.
   `RTLD_LOCAL` keeps the core's names out of the global namespace, so a
   second core opened later cannot bind to them.
2. Read each bridge function with `dlsym` on that handle, never with
   `RTLD_DEFAULT`.
3. Open the core when the user picks a game, not at launch. A core that is
   never picked is never loaded.

Empo does step 2 through `ios/Empo/src/App/GameCoreForwarders.c`, which
`tools/gamecore/generate-core-forwarders.sh` writes from `GameCore.h`. Every
`gamecore_*` call in the app lands in a forwarder that asks the open core for the
same name under that core's prefix. `EngineSessionCoordinator` passes the prefix
to `EmpoCoreOpen` next to the framework path. A call made before the core opens
aborts with the name it wanted, because a silent no-op would hide a build
mistake until a game misbehaved.

## Which thread runs the game

The two cores differ, and neither choice is free.

`gamecore_run_app` runs on the main thread and returns when the game ends. Call it
from a run loop callout, such as `RunLoop.main.perform`. Do not call it from a
block on the main dispatch queue. It holds the thread for the whole session,
so that queue would never drain, and the engine's RGSS thread deadlocks on its
first `gamecore_getScreenScale`, which `dispatch_sync`s to the main queue. SDL's
nested `runMode:beforeDate:` inside `SDL_PumpEvents` drains a run loop
normally, which is why the callout works.

`psdk_run`, which is the PSDK core's own entry point and not part of the
launcher interface, runs on a worker thread and needs a 16 MB stack. SFML marshals
every UIKit call to the main thread with `dispatch_sync`, so the main thread
has to stay in its run loop and answer them. Ruby's parser and the PSDK boot
scripts also recurse past the default 512 KB worker stack.

## Where a core keeps its own files

A core reads its assets from its own bundle. `filesystemImplIOS.mm` calls
`dladdr` on one of its own functions, takes the folder that holds that image,
and reads `Assets.bundle` there. So the shaders, the fonts, the preload and
postload scripts and the Ruby standard library all ship inside
`MkxpCore.framework`, and the app ships none of them. The app keeps only its
own files, such as `cacert.pem` and the splash icons.

The launcher still owns the game's own folder. `getDefaultGameRoot` reads the
main bundle, and Empo hands the path in with `gamecore_setGamePath`.

## What the launcher reads before it opens a core

Empo has to reject a game its core cannot run, and import runs off the main
thread before any core is open. So the answer cannot come from a bridge call.
`tools/mkxp-core/build-framework-ios.sh` writes `EmpoCoreRGSSVersionMask` into
the framework's `Info.plist` from the same build flag the engine reads, and
`BuiltInGameCore.rgssVersionMask` reads the key from the bundle.

Both `build-framework-ios.sh` scripts also write `EmpoCoreVersion`, which names
the engine source the core was linked from. The Game cores screen shows it.

## One core for each process

Empo plays one game for each process (`multi-session.md`), so it opens one
core and keeps it. Two cores in one process load without binding to each
other, and `tools/mkxp-core/host.m` proves that with `MKXP_ALSO_OPEN`. Running
two at once is a different question. Both want the working directory, the
signal handlers, the audio device and the main thread.

## Which source a release names

Each core comes from its own engine repo: `MkxpCore` from
`mkxp-z-apple-mobile`, `PsdkCore` from `litergss2-apple-mobile`. A release
tags the pinned commit in both repos with `empo-v<version>`, so anyone can
check out the source that built the shipped binary. `scripts/release.sh` and
the `cut` job in `.github/workflows/release.yml` create the two tags, and both
refuse a commit that is not on that repo's `dev` branch.

`EmpoCoreVersion` holds `git describe` of that repo, so both rows on the Game
cores screen carry the same tag name after a release. Before the first release
that ships a core, `describe` has no tag to name and falls back to the short
commit.

The PSDK core also links LiteCGSS, the SFML fork and Ruby 3.0, and no tag
names those. The dependency fingerprint ties the framework to every pinned
commit, so the tagged commit is still the one that built it.

## How the framework stays fresh

The native tree keeps the built framework between builds, and Xcode only
copies it. `build-framework-ios.sh` writes its own sha256 into
`.build-script-sha256` inside the framework, and `check-*-framework.sh` fails
when that hash stops matching the script on disk. Rebuild MkxpCore with
`scripts/rebuild-engine-halves.sh <sdk>`, and PsdkCore with
`tools/psdk-core/build-framework-ios.sh --sdk <sdk>`. Both take minutes.
`rebuild-engine-halves.sh` builds the mkxp half only. The dependency
fingerprint does not list the packaging scripts, because they build an engine
output and a full dependency rebuild takes hours.

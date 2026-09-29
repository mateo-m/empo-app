---
title: Cores
description: What a game core is, what it must export, and the rules a launcher follows to open one.
---

## What a core is

A core is one dynamic framework that holds a whole game engine. It carries
its own Ruby, its own classes, its own SDL or SFML, and its own assets. Empo
has six:

- `MkxpCore.framework`: mkxp-z, with Ruby 1.8, 1.9 and 3.1, on SDL2.
- `Psdk25Core.framework`, `Psdk30Core.framework`, `Psdk32Core.framework` and
  `Psdk33Core.framework`: LiteRGSS2 and LiteCGSS on SFML, each with one Ruby.
  Pokémon Studio compiles a game with Ruby 3.0 on Windows, 3.2 on a Mac and
  3.3 on Linux. PSDK games from December 2019 to about March 2021 use Ruby
  2.5. The app reads the version in `Game.yarb` and opens the core of that
  Ruby.
- `MvmzCore.framework`: a `WKWebView` for RPG Maker MV and MZ. Each of
  these games ships its own JavaScript engine, so the core holds no engine.
  It serves the game folder to the web view, and its `runtime.js` gives the
  game the NW.js names it reads, such as `require("fs")`.

Both engines declare a class named `ViewportElement` at global scope, and both
carry a full Ruby. Linking both into one binary makes them share those names.
A dynamic framework with an export list does not. That is why a core is a
framework and not a static library.

## What a build ships

A build carries one or more cores. `EMPO_CORES` in `ios/Empo/project.yml`
names the cores, and the "Embed the cores" phase copies those frameworks into
the app. Ship one core from the command line:

```sh
xcodebuild ... EMPO_CORES=Psdk30Core
```

The app reads its own bundle to find what it got. `GameCores.inThisBuild`
lists the cores whose framework is there, and the Game cores screen shows that
list. `GameCores.core(forGameAt:)` says which core a game folder needs. Empo
refuses a game whose core is absent in two places. The import stops and names
the missing core, and the library shows the same sentence when the player taps
the card.

`GameImportValidator` answers a different question: are these files a game.
It must not ask which cores the build has. `GameCatalog` calls it on every scan
and can delete a container it calls invalid, and a missing core is not a broken
game.

## What a core tells the app

Each core has a Swift type in `ios/Empo/src/Cores/<Name>/` that conforms to
`GameCore` (`ios/Empo/src/Cores/GameCore.swift`). The rest of the app asks
that type and never names a core, a language or an engine. The type answers:

- which folders are its games, and what an archive probe extracts to find them
- how an import checks a game, and what it does after the files land
- the title and the title picture of a game
- the JoiPlay archive types it runs
- its settings page, and the settings it sends when a game starts
- a warning to show before a game starts
- the four keys of the builtin button grid
- the rows of the Runtime section in Game Info
- whether it answers the cheat toggle, and whether a game can start in place
  of a paused game
- the tool the games were made with, `madeWith`, such as "RPG Maker" or
  "PSDK". The Game cores screen shows one group for each tool, and the user
  opens a group to read about its cores.

The first core in `GameCores.all` that accepts a folder runs it. To add a core,
add its bridge in `cores/<core>/`, its framework and its type, then add the
type to that list.

Ruby loads only bytecode of its own version, and Pokémon Studio compiles a
release with Ruby 3.0 on Windows, 3.2 on a Mac and 3.3 on Linux. So there is
one PSDK core for each Ruby. `PsdkCore.all` lists them, and each core accepts
only a game whose `Game.yarb` has its version. The Ruby 3.0 core also takes
each PSDK folder that no core can run, and the import refuses it there. A
release compiled with `--no-yarb` has plain Ruby and no `Game.yarb`, so it
runs on the Ruby 3.0 core. Ruby
3.0 also reads Ruby 3.0 bytecode compiled by hand on 64-bit Linux or a Mac.

The PSDK core lives in its own repo, `psdk-apple-mobile`. Each release holds
`libpsdk<NN>.a` for each Ruby: one object with the Ruby, its extensions,
LiteRGSS2, LiteCGSS, SFML, OpenAL Soft and OpenSSL, which defines only the
names of `psdk_core.h`. `cores/psdk/.version` pins the release.
`cores/psdk/build-framework-ios.sh` links each library with
`psdk_app_bridge.cpp`, which answers the launcher interface with the core's
calls, into `Psdk<NN>Core.framework`. Xcode runs it before each build.

Each PSDK framework carries its own SFML, with the Objective-C classes
`SFAppDelegate`, `SFView` and `SFViewController`. Objective-C keeps one class
for each name in a process, so a second PSDK core must not open in a process.
It cannot, because a PSDK core cannot kill its game (`canKillSession`).

PSDK releases from December 2019 to about March 2021 carry Ruby 2.5 bytecode.
They were written for LiteRGSS 1 and play sound only through FMOD, a
closed-source Windows library. The 2.5 core claims only Ruby 2.5 bytecode, and
its support folder adds two Ruby files. `litergss1.rb` puts the LiteRGSS 1
`Graphics`, `Input`, `Mouse` and `Viewport` calls back on top of LiteRGSS2.
`RubyFmod.rb` gives the FMOD calls of those games, and plays the sound through
SFMLAudio. Each support folder also holds `compat.rb`, the fixes for things
released games do, which the core loads before the game.

The MV and MZ core lives in its own repo, `mvmz-apple-mobile`. Each release
holds `libmvmz.a`, which defines only the names of `mvmz_core.h`.
`cores/mvmz/.version` pins the release, and
`cores/mvmz/fetch.sh` downloads it before the MvmzCore target builds.
The target links the library with `mvmz_app_bridge.m`, which puts the web view
in its own window and in the launcher's region, and answers the launcher
interface with the core's calls.

The four PSDK cores export the same `psdk_*` names. Each forwarder looks the
name up in the one core it opened, so the names do not meet.

A setting that only one core knows goes through `gamecore_setSetting` as text.
Each core's bridge lists its keys. The debug overlay shows the
lines of `gamecore_getDetails`, which the core writes.

`scripts/audit-ipa.sh` audits the cores it finds in the bundle. Pass
`--cores "MkxpCore Psdk30Core"` to demand an exact set.

## What a core exports

A core exports the functions of `cores/GameCore.h` and nothing else. Each
core links with the list that `cores/gamecore-exports.sh` writes from that
header, so the link fails when the bridge leaves a function out.

No core exports a Ruby name, an SDL name or an SFML name, and no core imports
one either. `cores/mkxp/check-framework.sh` and
`cores/psdk/check-framework.sh` fail the build when that stops being true.
They also fail when a core leaves the two-level namespace, because a flat
namespace would let a second core bind to the first core's names.

## What a launcher setting means for each core

Empo sends every core the same shared settings. Each core answers with what
its own engine has. The PSDK cores answer four:

| Setting | What a PSDK core does |
| --- | --- |
| Fixed aspect ratio | `placeOutputRegion` fits the picture in the launcher's region and centres it. |
| Smooth scaling | The SFML fork reads the flag in the `sf::Texture` constructor, so every picture the game makes after that is smooth. The game's own resolution goes up to the screen with the GL viewport, so the filter of each texture decides how the whole picture looks. A texture reads the flag once, so a new value needs a restart. |
| Touch acts as mouse | LiteRGSS2 sends touches to a game that reads them. In a game that reads only the mouse, the first finger moves the mouse and holds the left button. While the switch is off, no touch reaches the game. |
| Fast forward | The core's `compat.rb` multiplies the frame rate that `Graphics::FPSBalancer` reads. The balancer divides the real clock by that rate and runs that many game frames, so the game runs faster and still draws at the same rate. A new value applies while the game runs. |

The MV and MZ core answers two:

| Setting | What the MV and MZ core does |
| --- | --- |
| Smooth scaling | Off, the core's `runtime.js` draws the canvas with `image-rendering: pixelated`. A new value needs a restart. |
| Fast forward | MV runs one update for each `SceneManager._deltaTime` seconds, so `runtime.js` divides it. MZ runs the count that `SceneManager.determineRepeatNumber` returns for each frame, so `runtime.js` multiplies it. A new value applies while the game runs. |

The MV and MZ core always fits the picture in the region. The game keeps
its own proportions inside the web view, and it maps touches through that
fit, so the core has no fixed aspect ratio setting.

The other rows belong to mkxp-z: render scale, frame skip, solid fonts,
postload scripts, the path cache, the in-game keyboard, JoiPlay
compatibility, the Ruby version and network access. Each core puts its own
settings page together in `settingsPage(_:)`, from the shared sections in
`GameSettingsSections.swift` and its own. The rows only mkxp-z reads live in
`ios/Empo/src/Cores/Mkxp/MkxpSettings.swift`.

## What the engine asks the bridge

Nothing. A core never calls the launcher, and no core repo names Empo. Each
core's repo has a check that fails on a launcher name or a weak host function.
The bridge sets each value and each callback through the engine's own
interface:

| Core | Bridge in this repo | Engine interface, from the core's release |
| --- | --- | --- |
| MkxpCore | `cores/mkxp/mkxp_app_bridge.c` | `include/app_bridge.h` |
| The PSDK cores | `cores/psdk/psdk_app_bridge.cpp` | `psdk_core.h` |
| MvmzCore | `cores/mvmz/mvmz_app_bridge.m` | `mvmz_core.h` |

## One interface for every core

`cores/GameCore.h` is the one interface between a launcher and a core. It
names no engine. Every bridge includes it and defines each function under the
same `gamecore_` name, so the compiler checks each signature against it.

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
same name. A call made before the core opens
aborts with the name it wanted, because a silent no-op would hide a build
mistake until a game misbehaved.

## Which thread runs the game

The cores differ, and no choice is free.

`gamecore_run_app` runs on the main thread and returns when the game ends. Call it
from a run loop callout, such as `RunLoop.main.perform`. Do not call it from a
block on the main dispatch queue. It holds the thread for the whole session,
so that queue would never drain, and the engine's RGSS thread deadlocks the
first time it reads the screen scale, which `dispatch_sync`s to the main queue. SDL's
nested `runMode:beforeDate:` inside `SDL_PumpEvents` drains a run loop
normally, which is why the callout works.

`psdk_run`, which is a PSDK core's own entry point and not part of the
launcher interface, runs on a worker thread and needs a 16 MB stack. SFML marshals
every UIKit call to the main thread with `dispatch_sync`, so the main thread
has to stay in its run loop and answer them. Ruby's parser and the PSDK boot
scripts also recurse past the default 512 KB worker stack.

The MV and MZ `gamecore_run_app` gets the web view from `mvmz_start` and returns. WebKit runs
the game in its own processes, and the main thread only answers WebKit. WebKit
suspends the page of a web view that is in no visible window, so the bridge
shows its window at once, under the Empo window.

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
`cores/mkxp/build-framework-ios.sh` writes `EmpoCoreRGSSVersionMask` into
the framework's `Info.plist` from the same build flag the engine reads, and
`MkxpCore.rgssVersionMask` reads the key from the bundle.

Both `build-framework-ios.sh` scripts also write `EmpoCoreVersion`, which names
the engine source the core was linked from. The Game cores screen shows it.

## More than one core in a process

A core opens only after the open core killed its game with
`gamecore_killSession` (`multi-session.md`). Only a core whose Swift type says
`canKillSession` can do that, so an MV or MZ game can come before a Ruby game,
but not after one. `EmpoCoreOpen` refuses any other change of core, and
`EngineSessionCoordinator.openCore` then stops the app. Two cores in one
process load without binding to each other, and `cores/mkxp/test-host/host.m`
proves that with `MKXP_ALSO_OPEN`. Two cores cannot run at once. Both want the
working directory, the signal handlers, the audio device and the main thread.

The killed core stays loaded, because `dlclose` does not unload a framework
with Objective-C classes. Each forwarder in `GameCoreForwarders.c` looks its
symbol up again after a different core opens.

Objective-C registers every class by name for the whole process, also when
its symbol is hidden. `scripts/audit-ipa.sh` fails a release when the app or
two cores declare the same class name. It counts the four PSDK cores as one,
because no two of them open in a process.

## Which source a release names

Each core comes from a release of its own engine repo, and the tag in its
`.version` file names the source. The engine repos hold no launcher code.
Everything that wraps a core for Empo is in `cores/<core>/`: the pin, the
fetch script, the bridge, and the framework build. `MkxpCore` comes from `mkxp-z-apple-mobile`
(`cores/mkxp/.version`). The PSDK cores come from
`psdk-apple-mobile` (`cores/psdk/.version`). `MvmzCore` comes from
`mvmz-apple-mobile` (`cores/mvmz/.version`). Each release workflow
builds from the tagged commit, so anyone can check out the source that built
the shipped binary.

In each core, `EmpoCoreVersion` holds the release tag that the core's
`.version` file pins, for example `v1`. The Game cores screen shows it.

## How the framework stays fresh

MkxpCore links again before a build when the engine pin, the ANGLE pin or
the script changes. The PSDK cores link again when the core pin, the ANGLE
pin, the script or the bridge changes. A stamp next to each framework records
them.

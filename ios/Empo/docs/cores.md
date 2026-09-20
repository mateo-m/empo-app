---
title: Cores
description: What a game core is, what it must export, and the rules a launcher follows to open one.
---

## What a core is

A core is one dynamic framework that holds a whole game engine. It carries
its own Ruby, its own classes, its own SDL or SFML, and its own assets. Empo
ships two:

- `MkxpCore.framework`: mkxp-z, with Ruby 1.8, 1.9 and 3.1, on SDL2.
- `PsdkCore.framework`: LiteRGSS2 and LiteCGSS, with Ruby 3.0, on SFML.

Both engines declare a class named `ViewportElement` at global scope, and both
carry a full Ruby. Linking both into one binary makes them share those names.
A dynamic framework with an export list does not. That is why a core is a
framework and not a static library.

## What a core exports

A core exports its bridge and nothing else. `MkxpCore` exports the 102 `mkxp_*`
names that `mkxp-z-apple-mobile/src/app_bridge.h` declares. `PsdkCore` exports
the two `psdk_*` names that `ios/Dependencies/psdk/psdk_core.h` declares.

No core exports a Ruby name, an SDL name or an SFML name, and no core imports
one either. `scripts/check-mkxp-framework.sh` and
`scripts/check-psdk-framework.sh` fail the build when that stops being true.
They also fail when a core leaves the two-level namespace, because a flat
namespace would let a second core bind to the first core's names.

## How a launcher opens a core

1. Open the framework binary with `dlopen(path, RTLD_NOW | RTLD_LOCAL)`.
   `RTLD_LOCAL` keeps the core's names out of the global namespace, so a
   second core opened later cannot bind to them.
2. Read each bridge function with `dlsym` on that handle, never with
   `RTLD_DEFAULT`.
3. Open the core when the user picks a game, not at launch. A core that is
   never picked is never loaded.

Empo does step 2 through `ios/Empo/src/App/MkxpCoreForwarders.c`, which
`tools/mkxp-core/generate-core-forwarders.sh` writes from the bridge header.
Every `mkxp_*` call in the app lands in a forwarder that reads its symbol from
the open core. A call made before the core opens aborts with the name it
wanted, because a silent no-op would hide a build mistake until a game
misbehaved.

## Which thread runs the game

The two cores differ, and neither choice is free.

`mkxp_run_app` runs on the main thread and returns when the game ends. Call it
from a run loop callout, such as `RunLoop.main.perform`. Do not call it from a
block on the main dispatch queue. It holds the thread for the whole session,
so that queue would never drain, and the engine's RGSS thread deadlocks on its
first `mkxp_getScreenScale`, which `dispatch_sync`s to the main queue. SDL's
nested `runMode:beforeDate:` inside `SDL_PumpEvents` drains a run loop
normally, which is why the callout works.

`psdk_run` runs on a worker thread and needs a 16 MB stack. SFML marshals
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
main bundle, and Empo hands the path in with `mkxp_setGamePath`.

## What the launcher reads before it opens a core

Empo has to reject a game its core cannot run, and import runs off the main
thread before any core is open. So the answer cannot come from a bridge call.
`tools/mkxp-core/build-framework-ios.sh` writes `EmpoCoreRGSSVersionMask` into
the framework's `Info.plist` from the same build flag the engine reads, and
`GameImportValidator` reads the key from the bundle.

## One core for each process

Empo plays one game for each process (`multi-session.md`), so it opens one
core and keeps it. Two cores in one process load without binding to each
other, and `tools/mkxp-core/host.m` proves that with `MKXP_ALSO_OPEN`. Running
two at once is a different question. Both want the working directory, the
signal handlers, the audio device and the main thread.

## How the framework stays fresh

The native tree keeps the built framework between builds, and Xcode only
copies it. `build-framework-ios.sh` writes its own sha256 into
`.build-script-sha256` inside the framework, and `check-*-framework.sh` fails
when that hash stops matching the script on disk. Rebuild with
`scripts/rebuild-engine-halves.sh <sdk>`, which takes minutes. The dependency
fingerprint does not list the packaging scripts, because they build an engine
output and a full dependency rebuild takes hours.

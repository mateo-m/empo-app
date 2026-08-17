---
title: "Config files: JSON5"
description: The JSON5 dialect that Empo and its engine both parse, the files that use it, and the quirks to know about.
---

Empo and its engine parse config files with the same parser: json5pp, the engine's JSON5
implementation. The app embeds the identical parser through the `ios/Json5` package. A file
that one side parses, the other side also parses.

| File                 | Read by      |
| -------------------- | ------------ |
| `mkxp.json`          | engine + app |
| `empo/controls.json` | app          |
| `patches.json`       | engine       |

## What you can write

Everything in JSON5:

- `//` line comments and `/* */` block comments
- Trailing commas in objects and arrays
- Single-quoted strings
- Unquoted keys (`fullscreen: true`)
- Hex numbers (`0x1F`), numbers with a leading or trailing decimal point, an explicit `+` sign
- `\` line continuations inside strings

Both parsers preserve `//` sequences **inside** quoted strings (for example URLs).

## Quirks to know

- An unquoted key must touch its colon. Write `fullscreen: true` or `"fullscreen" : true`.
  Both parsers reject `fullscreen : true` (unquoted key with a space before the colon).
- The literals `infinity` and `NaN` parse on both sides, but the app approximates their
  values. Do not use them in config files.

## Session flags outside mkxp.json

Network access is **not** an `mkxp.json` key. It is a per-boot host bridge
flag (`MKXPSessionConfig.networkEnabled`, from the per-game "Network access"
setting, default on). Game scripts and patches can branch on it via
`System.network_enabled?`. When the flag is false, the game sees the
equivalent of airplane mode. Network libraries load and their classes exist,
but the native client refuses requests. Socket connects raise
`Errno::ENETDOWN`, and downloads report failure. Games then take the same
offline fallback paths that they ship for desktop players without internet.
Postload stubs for Windows-only online modules still apply while the game is
offline. The host provides the TLS trust store (`mkxp_setCABundlePath`,
exported to Ruby as `SSL_CERT_FILE`). The launcher refreshes the store
silently.

## Data directory keys (`dataPathOrg`, `dataPathApp`)

mkxp-z's `dataPathOrg` / `dataPathApp` keys control where the game's writable data directory
(`System.data_directory`) lives. On desktop they feed `SDL_GetPrefPath(org, app)`. Empo mirrors
that for every game: the data directory is the shared `Documents/Data/<org>/<app>/` tree, next
to `Games/` in the Files app. The keys come from `Game/mkxp.json` merged with the per-game
`EmpoState/mkxp.json` overlay (overlay wins). An org of `.` (or blank) contributes no path
component. A missing `dataPathApp` falls back to the game's INI title, then to the game's
library folder name. (Desktop mkxp-z falls back to the literal `mkxp-z` instead. On a device
with many installed games that would pool every title-less game into one directory, where
their save files collide.) Existing directories match case-insensitively, so a release whose
title changed only in case keeps its saves. Any two game releases that resolve to the same
pair see the same directory, so re-importing a newer version of a game keeps its saves.

At each launch, Empo moves the contents of the game's legacy `UserData/` directory into its
shared data directory, so saves written by older Empo versions carry over. When both sides
have a file with the same name, the newer file keeps the name. The older file stays beside it
as `<name>.empo-displaced.bak`. When both files hold the same bytes, Empo keeps one copy.
Deleting a game does not delete its shared data directory.

Some games keep their saves next to their own files instead ("portable mode"). When you
delete such a game, Empo moves the save files it finds inside `Game/` into
`Documents/Rescued Saves/<title>/`, with their structure intact. The bucket is named by the
game's display title. A marker file inside it records the game's library folder name. When
you import the same game again, Empo matches the bucket by that marker and moves the saves
back into the new `Game/` tree. If Empo does not recognize a save file, the deletion removes
it with the game.

## Related

- [Ship custom controls](/controls-format): the `empo/controls.json` manifest
- [patches-format.md](https://github.com/mateo-m/mkxp-z-apple-mobile/blob/main/docs/patches-format.md) in the engine repo: the `patches.json` script-patching format

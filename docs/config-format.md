# Config files: JSON5

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
that:

- Neither key declared: the per-game `Documents/Games/<title>/UserData/` directory.
- Either key declared (in `Game/mkxp.json` or the per-game `EmpoState/mkxp.json` overlay, overlay
  wins): a shared `Documents/GameData/<org>/<app>/` directory. An org of `.` (or blank)
  contributes no path component, and a missing `dataPathApp` falls back to the game's INI title,
  then `mkxp-z`. Any two game releases declaring the same pair see the same directory, so
  re-importing a newer version of a game keeps its saves.

On the first launch after a game starts declaring these keys, the contents of its `UserData/`
directory move into the (freshly created) shared directory so existing saves carry over. An
already-populated shared directory is left untouched.

## Related

- [controls-format.md](controls-format.md): the `empo/controls.json` manifest
- [patches-format.md](https://github.com/mateo-m/mkxp-z-apple-mobile/blob/main/docs/patches-format.md) in the engine repo: the `patches.json` script-patching format

# Shipping custom controls with your game

Ship a file named `controls.json` with your game to set its touch
layout and gamepad mapping. Setup takes about five minutes.

## Quickstart

1. Create a file named `controls.json` next to `Game.ini`:

   ```jsonc
   {
     "$schema": "https://raw.githubusercontent.com/mateo-m/empo-app/main/docs/schemas/empo-controls.v1.schema.json",
     "version": 1,
     "touch": {
       "portrait": {
         "dpad": { "x": 0.14, "y": 0.74 },
         "buttons": [
           { "label": "OK",   "key": "KeyZ",      "x": 0.88, "y": 0.80 },
           { "label": "Back", "key": "KeyX",      "x": 0.74, "y": 0.86 },
           { "label": "Run",  "key": "ShiftLeft", "x": 0.88, "y": 0.62 }
         ]
       }
     },
     "controller": {
       "y": "F5"  // north face button opens the fishing minigame
     }
   }
   ```

2. Package and distribute the game as usual. Empo picks the file up at
   import.

That file works as-is: portrait shows your three buttons and the d-pad
where you placed them, and the north face button presses F5. Use a
manifest when Empo's defaults miss keys your game reads, such as script
hotkeys or a custom dash key. Players can rearrange everything on their
device; your file sets the starting point and the layout Reset returns
to.

The `$schema` line is optional. With it, editors like VS Code
autocomplete field names and flag typos as you type.

A complete commented example lives at
[`docs/examples/empo-controls-example.json`](examples/empo-controls-example.json).

## File locations

Empo checks three spots, in order:

1. `empo/controls.json` (a lowercase `empo` folder next to `Game.ini`)
2. `controls.json` next to `Game.ini`
3. `kirin-touch-controls.json` next to `Game.ini` (see
   [Kirin files](#kirin-files))

The root location is the standard one; other launchers can adopt it
without carrying Empo's name. The `empo/` location is an override for
Empo alone. When both files exist, Empo reads the `empo/` one and logs
that it skipped the other.

One rule applies to the root location only: the file must contain the
`version` key to count as a controls manifest. `controls.json` is a
generic file name, and some games ship one for their own scripts; Empo
leaves a root file without `version` alone instead of flagging it as
broken. A file inside `empo/` is validated no matter what.

## Kirin files

Kirin, the Android RPG Maker XP player, saves its touch layout as
`kirin-touch-controls.json` at the game root. If your game already
ships that file for Android players, Empo converts it on iOS: each
mapped key becomes a touch button, kept in Kirin's right-hand and
left-hand grid arrangement, with Kirin's scale and opacity applied.

The conversion carries over keys, grid order, scale, and opacity. It
drops button colors, d-pad changes, and the diagonal-movement toggle,
and it adds no controller bindings. Conversion notes go to the same log
file as manifest findings, and they never block loading; a Kirin file
Empo cannot use changes nothing.

Either manifest location above outranks the Kirin file, and a converted
Kirin layout sits in the same precedence slot as your `touch` section,
so players' own edits still win. Ship a manifest when you want the
layout under your control on both platforms, or when you need anything
Kirin's format cannot express: exact positions, per-button sizes,
labels, or controller mappings.

## File format

The file is JSON with one extension: `//` line comments are allowed.
Block comments (`/* */`), trailing commas, and single quotes are not.
Empo rejects files over 128 KiB. A real manifest is a few KiB, so the
cap only catches files that were never a manifest, such as a renamed
save file.

Top level:

| Field | Required | Meaning |
|---|---|---|
| `version` | yes | Must be `1` |
| `touch` | no | On-screen layout ([reference](#touch-reference)) |
| `controller` | no | Gamepad mapping ([reference](#controller-reference)) |

Ship either section or both. Empo ignores object keys it does not
recognize, so a file written for a future Empo version still loads on
older versions. Unknown values are errors: an unknown key code, element
name, or out-of-range number rejects the file. See
[Validation](#validation-and-debugging).

## Touch reference

```jsonc
"touch": {
  "portrait":  { "dpad": { ... }, "buttons": [ ... ] },
  "landscape": { "dpad": { ... }, "buttons": [ ... ] }
}
```

Each orientation is optional. An orientation you omit keeps Empo's
default layout. Within an orientation, `dpad` and `buttons` are each
optional too, with one distinction:

- `"buttons"` omitted: Empo's default buttons appear.
- `"buttons": []`: no buttons at all. Use this for mouse-driven games.

### Coordinates

`x` and `y` place the center of a control, as fractions of the touch
controls area:

```text
(0,0) ┌─────────────┐ (1,0)
      │             │
      │   controls  │
      │     area    │
      │             │
(0,1) └─────────────┘ (1,1)
```

`{ "x": 0.5, "y": 0.5 }` is dead center. Empo nudges controls that land
under a notch or home indicator back into the safe area at runtime, so
you do not need to account for individual devices.

### `dpad`

| Field | Required | Range | Default |
|---|---|---|---|
| `x`, `y` | yes | 0.0 to 1.0 | |
| `size` | no | 100 to 200 (points) | 140 |
| `opacity` | no | 0.2 to 1.0 | 1.0 |

Omit `dpad` to keep the default placement. There is no way to remove
the d-pad; these games need arrow keys.

### `buttons`

Up to 16 per orientation.

| Field | Required | Range | Default |
|---|---|---|---|
| `key` | yes | a [key code](#key-codes) | |
| `x`, `y` | yes | 0.0 to 1.0 | |
| `label` | no | 8 characters max | derived from the key |
| `size` | no | 40 to 100 (points) | 56 |
| `opacity` | no | 0.2 to 1.0 | 1.0 |

Empo truncates labels longer than 8 characters and logs a warning. Two
buttons may share a key; Empo logs a warning and allows it.

Any key from the [table below](#key-codes) works, including keys the
in-app edit screen does not offer, such as numpad keys. Empo sends real
keyboard scancodes to the engine, so if a desktop keyboard press
triggers something in your game, a touch button bound to that key will
too. That includes F-key script hotkeys and custom Input module
bindings.

## Controller reference

```jsonc
"controller": {
  "a": "Enter",
  "y": "F5",
  "righttrigger": "ShiftLeft",  // hold to run
  "lefttrigger": null,          // unbind
  "start": "$pauseMenu"
}
```

Each entry maps a gamepad element to a key code, an action, or `null`.

**Your map is a patch.** Empo has a built-in mapping (table below).
Your file changes only the elements you list, and `null` removes a
binding the built-in map had. This differs from touch, where a
`buttons` array replaces the whole set for that orientation.

**Element names are positional.** `a` means the south face button on any
controller: Xbox A, PlayStation Cross, and the Switch button labeled B
are all `a`. Map by physical position, never by the letter printed on
the button. This is the single most common mistake in controller
configs.

### Elements

| Group | Names |
|---|---|
| Face buttons | `a` (south), `b` (east), `x` (west), `y` (north) |
| D-pad | `dpup`, `dpdown`, `dpleft`, `dpright` |
| Sticks (direction) | `-leftx` (left), `+leftx` (right), `-lefty` (up), `+lefty` (down), and the same four for `rightx`/`righty` |
| Sticks (click) | `leftstick`, `rightstick` |
| Shoulders | `leftshoulder`, `rightshoulder` |
| Triggers | `lefttrigger`, `righttrigger` |
| System | `start` (Menu), `back` (Options/Select), `guide` (Home) |
| Extras | `paddle1` through `paddle4`, `touchpad` |

Notes:

- Stick directions use a sign convention: minus is left or up, plus is
  right or down. `-lefty` fires when the player pushes the left stick
  up.
- Triggers and stick directions act as digital buttons: pressed at 50%
  travel, released below 40%, so a half-pulled trigger never flutters.
- iOS often reserves `guide` for the system. You can bind it, but test
  on a real device before relying on it.
- Paddles and touchpad only exist on some controllers (Xbox Elite,
  DualSense). Bindings for absent hardware do nothing.

### Actions

Values starting with `$` trigger Empo features instead of keys.
Controller maps only; touch buttons cannot bind actions.

| Action | Effect |
|---|---|
| `$pauseMenu` | Open and close Empo's pause menu |
| `$toggleOverlay` | Show and hide the touch controls |

### Built-in map

The base your file patches:

| Element | Binding |
|---|---|
| `a` | `Enter` (confirm) |
| `b` | `Escape` (cancel) |
| `x` | `ShiftLeft` (dash) |
| `y` | `KeyA` |
| `dpup`/`dpdown`/`dpleft`/`dpright` | Arrow keys |
| Left stick directions | Arrow keys |
| `leftshoulder` / `rightshoulder` | `KeyQ` / `KeyW` |
| `leftstick` / `rightstick` | `KeyS` / `KeyD` |
| `start` | `$pauseMenu` |
| `back` | `$toggleOverlay` |

Triggers, the right stick, `guide`, paddles, and touchpad start
unbound.

## Key codes

Key names follow the W3C `KeyboardEvent.code` standard, the same strings
JavaScript reports in a browser. Matching is case-sensitive.

| Codes | Notes |
|---|---|
| `KeyA` … `KeyZ` | Letters |
| `Digit1` … `Digit9`, `Digit0` | Number row |
| `Enter`, `Escape`, `Backspace`, `Tab`, `Space` | |
| `Minus`, `Equal`, `BracketLeft`, `BracketRight`, `Backslash` | |
| `Semicolon`, `Quote`, `Backquote`, `Comma`, `Period`, `Slash` | |
| `CapsLock` | |
| `F1` … `F12` | Script hotkeys live here |
| `PrintScreen`, `ScrollLock`, `Pause` | |
| `Insert`, `Home`, `PageUp`, `Delete`, `End`, `PageDown` | |
| `ArrowRight`, `ArrowLeft`, `ArrowDown`, `ArrowUp` | |
| `NumLock`, `NumpadDivide`, `NumpadMultiply`, `NumpadSubtract`, `NumpadAdd`, `NumpadEnter`, `NumpadDecimal` | |
| `Numpad1` … `Numpad9`, `Numpad0` | |
| `IntlBackslash`, `IntlRo`, `IntlYen` | Japanese keyboards |
| `ControlLeft`, `ShiftLeft`, `AltLeft`, `MetaLeft` | Left-side modifiers |
| `ControlRight`, `ShiftRight`, `AltRight`, `MetaRight` | Right-side modifiers |

### RGSS cheat sheet

Which keyboard keys the engines read by default:

| Game input | XP | VX / VX Ace | Typical meaning |
|---|---|---|---|
| C | `Enter`, `Space` | `Enter`, `Space`, `KeyZ` | Confirm, interact |
| B | `Escape`, `KeyX` | `Escape`, `KeyX` | Cancel, open menu |
| A | `ShiftLeft`, `KeyZ` | `ShiftLeft` | Dash |
| X / Y / Z | `KeyA` / `KeyS` / `KeyD` | `KeyA` / `KeyS` / `KeyD` | Free for scripts |
| L / R | `KeyQ` / `KeyW` | `KeyQ` / `KeyW` | Page up / page down |

The trap: `KeyZ` confirms on VX and VX Ace but maps to the A button on
XP. `Enter` and `Space` confirm on all three engines, which is why the
built-in gamepad map uses `Enter` for the south button. If your game
replaces the Input module (Pokémon Essentials does), your bindings win;
base your map on them instead of on this table.

## Precedence

Touch layout, first match wins:

1. The player's own edits on their device
2. Your `touch` section
3. Empo's defaults

The Reset button in Empo's edit mode returns players to layer 2 when
your file provides it, labeled "Reset to game default."

Controller bindings merge per element, later layers override:

1. Empo's built-in map
2. The player's global overrides (all games)
3. Your `controller` section
4. The player's overrides for your game

Your file outranks a player's global preferences because you know your
game's scripts. The player keeps the last word for your specific game.
Design your map as the best default, and expect players to tweak it.

## Validation and debugging

Empo validates the whole file at load. One error rejects the entire
file, and the game falls back to defaults as if the file were absent.
There is no partial application: players get either your exact layout or
Empo's, never a mix you have not tested.

A rejected file is loud on purpose. Empo writes every finding to the
game's log folder (`Logs/controls.json.log` inside the game's container)
and shows a notice in the edit-controls screen: "This game ships a
controls.json with N errors." Ask a tester for that log line if a report
says your controls did not show up.

| Code | Meaning |
|---|---|
| V000 | Broken JSON, or a value of the wrong type |
| V001 | File exceeds 128 KiB |
| V002 | `version` missing or not `1` |
| V010 | Unknown key code (the message echoes the bad string) |
| V011 | Coordinate missing or outside 0.0 to 1.0 |
| V012 | Size or opacity out of range |
| V013 | More than 16 buttons in one orientation |
| V014 | `$action` on a touch button |
| V020 | Unknown controller element |
| V021 | Unknown `$action` |
| W001 | Neither `touch` nor `controller` present (warning) |
| W002 | Label truncated to 8 characters (warning) |
| W003 | Two buttons share one key (warning) |

Warnings never reject the file.

To catch errors before shipping, validate against the
[JSON Schema](schemas/empo-controls.v1.schema.json) in any JSON-aware
editor, or with a validator like `ajv`.

## Versioning

`version` is an integer, currently always `1`.

- New optional fields will arrive without a version bump. Old Empo
  versions ignore fields they do not know.
- An Empo that only knows version 1 ignores a `version: 2` file in
  full. Newer formats never half-apply.
- Version 1 files work forever. If a version 2 ever exists, every
  future Empo keeps reading version 1 files exactly as this document
  describes. Shipping a `controls.json` today is safe.

## Before you ship

1. Validate the file: with the `$schema` line, your editor flags errors
   as you type; any JSON Schema validator works too. One minute.
2. Import the game in Empo and open the edit-controls screen. A broken
   file shows an error notice there, with details in the game's
   `Logs/controls.json.log`. Five minutes.
3. If you ship a `controller` section, connect a gamepad and press each
   remapped element once in-game. Five minutes.

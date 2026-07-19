# Shipping custom controls with your game

Empo runs RPG Maker XP, VX, and VX Ace games that were designed for a
keyboard. The default on-screen controls cover the standard bindings, but
your game may use F5 for a fishing minigame, X for a quest log, or a
custom dash key. `empo/controls.json` lets you ship the right controls
with the game itself: your own touch button layout, and a gamepad mapping
tuned to how your game reads the keyboard.

Players can still rearrange everything on their device. Your file changes
the starting point, and the layout players return to when they hit Reset.

## Quickstart

1. Create a folder named `empo` (lowercase) next to `Game.ini`.
2. Add a file named `controls.json` inside it:

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

3. Package and distribute the game as usual. Empo picks the file up at
   import.

The `$schema` line is optional. With it, editors like VS Code
autocomplete field names and flag typos as you type.

A complete commented example lives at
[`docs/examples/empo-controls-example.json`](examples/empo-controls-example.json).

## File format

The file is JSON with one extension: `//` line comments are allowed.
Block comments (`/* */`), trailing commas, and single quotes are not.
Keep the file under 128 KiB.

Top level:

| Field | Required | Meaning |
|---|---|---|
| `version` | yes | Must be `1` |
| `name` | no | A label for your own bookkeeping; Empo does not display it |
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

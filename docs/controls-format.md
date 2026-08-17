---
title: Ship custom controls
description: Ship a controls.json file with your game to set its touch layout, its screen region, and its gamepad mapping.
---

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
     "bindings": {
       "y": "F5"  // north face button opens the fishing minigame
     }
   }
   ```

2. Package and distribute the game as usual. Empo picks the file up at
   import.

That file works as written. Portrait mode shows your three buttons and
the d-pad where you placed them. The north face button presses F5. Use
a manifest when Empo's defaults miss keys your game reads, such as
script hotkeys or a custom dash key. Players can rearrange everything
on their device. Your file sets the starting point and the layout that
Reset returns to.

The `$schema` line is optional. With it, editors like VS Code
autocomplete field names and flag typos as you type.

A full commented example is at
[`docs/examples/controls.json`](https://github.com/mateo-m/empo-app/blob/main/docs/examples/controls.json).

## File locations

Empo checks four locations, in this order:

1. `empo/controls.json` (a lowercase `empo` folder next to `Game.ini`)
2. `controls.json` next to `Game.ini`
3. `kirin-touch-controls.json` next to `Game.ini` (see
   [Files from other launchers](#files-from-other-launchers))
4. `gamepad.json` next to `Game.ini` (JoiPlay's file, same section)

The root location is the standard one. Other launchers can adopt it,
because the file name does not contain Empo's name. The `empo/`
location is an override for Empo alone. When both files exist, Empo
reads the `empo/` one and logs that it skipped the other.

One rule applies to the root location only: the file must contain the
`version` key to count as a controls manifest. `controls.json` is a
generic file name, and some games ship one for their own scripts. Empo
leaves a root file without `version` alone and does not flag it as
broken. Empo always validates a file inside `empo/`.

## Files from other launchers

If your game already ships a touch layout for an Android launcher,
Empo converts it on iOS. Both conversions follow the same rules. The
file stays in your game folder, and Empo reads it again at each
launch. The converted layout sits in the same precedence slot as your
`touch` section, so players' own edits still win. Conversion notes go
to the same log file as manifest findings. A file that Empo cannot use
changes nothing. Neither format adds button bindings.

**Kirin** saves its touch layout as `kirin-touch-controls.json`. Empo
keeps each mapped key as a touch button in Kirin's right-hand and
left-hand grid arrangement. Empo applies Kirin's scale and opacity.
Button colors, d-pad changes, and the diagonal-movement toggle do not
carry over.

**JoiPlay** ships `gamepad.json` inside JGP archives. Empo shows the
full eight-button pad (C, B, A, X, Y, Z, L, R) and applies your
`*KeyCode` overrides. For each slot without an override, Empo uses the
standard RPG Maker key (C=Enter, B=Esc, A=Shift, X/Y/Z=A/S/D,
L/R=Q/W). `btnScale` and `btnOpacity` carry over. Because
`gamepad.json` is a generic name, the file only counts when it
contains at least one JoiPlay key.

A controls manifest outranks both files, and Kirin's outranks
JoiPlay's. Ship a manifest when you want control of the layout on
every platform. Also ship one when you need what these formats cannot
express: exact positions, per-button sizes, labels, or controller
mappings.

## File format

The file is JSON with one extension: you can use `//` line comments.
You cannot use block comments (`/* */`), trailing commas, or single
quotes. Empo rejects files over 128 KiB. A real manifest is a few KiB.
The cap only catches files that were never a manifest, such as a
renamed save file.

Top level:

| Field | Required | Meaning |
|---|---|---|
| `version` | yes | Must be `1` |
| `touch` | no | On-screen layout ([reference](#touch-reference)) |
| `bindings` | no | Controller and keyboard mapping ([reference](#bindings-reference)) |

Ship either section or both. Empo ignores object keys it does not
recognize, so a file written for a future Empo version still loads on
older versions. Unknown values are errors: an unknown key code, element
name, or out-of-range number rejects the file. See
[Validation](#validation-and-debugging).

## Touch reference

```jsonc
"touch": {
  "portrait":  { "dpad": { ... }, "buttons": [ ... ], "actionButtons": [ ... ] },
  "landscape": { "dpad": { ... }, "buttons": [ ... ], "actionButtons": [ ... ] }
}
```

Each orientation is optional, and you only need to design one. When
you define a single orientation, Empo derives the other from it. Empo
keeps the same arrangement and refits it to the other screen shape.
Buttons keep their sizes and their relative placement. Spacing
tightens or relaxes to match the zone. Define both orientations when
you want full control of each.

Two special cases:

- `"landscape": {}` (an explicit empty object) opts that orientation
  into Empo's default layout instead of derivation.
- When you define neither orientation, both use Empo's defaults.

Within an orientation, `dpad` and `buttons` are each optional too,
with one distinction:

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

`{ "x": 0.5, "y": 0.5 }` is the exact center. At runtime, Empo moves
controls that land under a notch or home indicator back into the safe
area. You do not need to adjust for individual devices.

### `dpad`

| Field | Required | Range | Default |
|---|---|---|---|
| `x`, `y` | yes | 0.0 to 1.0 | |
| `size` | no | 100 to 200 (points) | 140 |
| `opacity` | no | 0.2 to 1.0 | 1.0 |
| `style` | no | `"dpad"` or `"stick"` | `"dpad"` |

Omit `dpad` to keep the default placement. You cannot remove the
d-pad, because these games need arrow keys.

`"style": "stick"` draws a joystick instead of the d-pad: a thumb
nub that follows the finger. The key mapping and the 8-way direction
math stay the same. The joystick allows diagonal movement closer to
the center than the d-pad does. Empo added `style` in version 0.6. Older versions ignore the
field and draw a d-pad. An unknown style value is a warning and
falls back to the d-pad, but note: when the player edits the layout,
the next save writes the field back only if Empo knows the value.

### `buttons`

Up to 21 per orientation, counted together with `actionButtons`.

| Field | Required | Range | Default |
|---|---|---|---|
| `key` | yes | a [key code](#key-codes) | |
| `x`, `y` | yes | 0.0 to 1.0 | |
| `label` | no | 8 characters max | derived from the key |
| `size` | no | 40 to 100 (points) | 56 |
| `opacity` | no | 0.2 to 1.0 | 1.0 |

Empo truncates labels longer than 8 characters and logs a warning.
Two buttons may share a key. Empo allows this and logs a warning.

Any key from the [table below](#key-codes) works, including keys the
in-app edit screen does not offer, such as numpad keys. Empo sends
real keyboard scancodes to the engine. If a desktop keyboard press
triggers something in your game, a touch button bound to that key
triggers it too. That includes F-key script hotkeys and custom Input
module bindings.

### `actionButtons`

A separate list for buttons that trigger Empo features instead of
game keys. Empo added this list in version 0.6. Older Empo versions
ignore the list and show the rest of your layout.

```jsonc
"actionButtons": [
  { "action": "$toggleFastForward", "x": 0.92, "y": 0.30, "size": 56 }
]
```

| Field | Required | Range | Default |
|---|---|---|---|
| `action` | yes | an [action](#actions) marked touch-valid | |
| `x`, `y` | yes | 0.0 to 1.0 | |
| `size` | no | 40 to 100 (points) | 56 |
| `opacity` | no | 0.2 to 1.0 | 1.0 |

Action buttons have no `label` field. Empo draws a fixed icon for
each action. The 21-button cap counts `buttons` and `actionButtons`
together.

`"actionButtons": []` means no action buttons. An omitted key means
the same in your file today, but in a player's saved layout an
explicit `[]` records "the player deleted them all". The same
omitted-vs-empty distinction `buttons` has.

An unknown `action` value skips only that button, with a warning. The
rest of the file loads. This lets a file written for a newer Empo
degrade cleanly.

Note: fast-forward buttons work only in games where the player set a
speed multiplier in Game Settings. In other games the button hides
during play.

## Bindings reference

```jsonc
"bindings": {
  "a": "Enter",
  "y": "F5",
  "righttrigger": "ShiftLeft",  // hold to run
  "lefttrigger": null,          // unbind
  "start": "$pauseMenu",

  "KeyJ": "a"                   // a pad in keyboard mode: this key is the A button
}
```

Each entry maps a source to a key code, an action, or `null`. A source
is a controller element or a keyboard key.

The section was called `controller` before it also held keys. That name
still works and always will. If a file has both, `bindings` wins and
Empo logs a warning (W007).

### Keyboard sources

Small controllers often have a keyboard mode, and some of them support
nothing else on iOS: the 8BitDo Micro is a keyboard to an iPhone unless
you put it in Switch mode. Such a pad sends a key per button, so iOS
never reports a controller at all.

Name the key as the source to bind it. Point it at a controller element
and the key inherits that button's binding, wherever the binding comes
from: Empo's default, your manifest, or the player's own remap:

```jsonc
"bindings": {
  "a": "KeyZ",     // the A button presses Z in this game
  "KeyJ": "a"      // and the pad's J key is the A button, so it presses Z too
}
```

Only keys can point at an element. An element pointing at an element
would be a chain, and Empo rejects it (V023).

A key you do not name reaches the game unchanged, so a real keyboard
keeps typing. Use `null` to silence a key.

Players do the same thing in the app: **Menu → Buttons → Keyboard →
Add a key** asks them to press the button, reads the key it sends, and
binds it.

**Your map is a patch.** Empo has a built-in mapping (table below).
Your file changes only the elements you list, and `null` removes a
binding from the built-in map. This differs from touch, where a
`buttons` array replaces the whole set for that orientation.

**Element names are positional.** `a` means the south face button on any
controller: Xbox A, PlayStation Cross, and the Switch button labeled B
are all `a`. Map by physical position, never by the letter printed on
the button. This is the most common mistake in controller configs.

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
- Triggers and stick directions act as digital buttons. They press at
  50% travel and release below 40%, so a half-pulled trigger never
  flutters.
- iOS often reserves `guide` for the system. You can bind it, but test
  on a real device before you rely on it.
- Paddles and touchpad only exist on some controllers (Xbox Elite,
  DualSense). Bindings for absent hardware do nothing.

### Actions

Values that start with `$` trigger Empo features instead of keys.
The bindings map can bind every action. The touch `actionButtons` list
can bind the touch-valid ones. A normal touch button's `key` field
can never hold an action.

| Action | Effect | Touch-valid |
|---|---|---|
| `$fastForward` | Speed the game up while held | yes |
| `$toggleFastForward` | Turn fast forward on or off | yes |
| `$pauseMenu` | Open and close Empo's pause menu | yes |
| `$toggleCheats` | Turn the cheats screen on or off | yes |
| `$toggleTouchControls` | Show and hide the touch controls | no |

The fast-forward actions work only in games where the player set a
speed multiplier. A controller binding to them does nothing in other
games.

`$toggleTouchControls` replaces the old name `$toggleOverlay`. Empo
rewrites the old name in the player's own files once. Update your
manifest to the new name. The old name now parses as an unknown
action (a warning, and the binding does nothing).

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
| `back` | `$toggleTouchControls` |

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

The keyboard keys that the engines read by default:

| Game input | XP | VX / VX Ace | Typical meaning |
|---|---|---|---|
| C | `Enter`, `Space` | `Enter`, `Space`, `KeyZ` | Confirm, interact |
| B | `Escape`, `KeyX` | `Escape`, `KeyX` | Cancel, open menu |
| A | `ShiftLeft`, `KeyZ` | `ShiftLeft` | Dash |
| X / Y / Z | `KeyA` / `KeyS` / `KeyD` | `KeyA` / `KeyS` / `KeyD` | Free for scripts |
| L / R | `KeyQ` / `KeyW` | `KeyQ` / `KeyW` | Page up / page down |

The trap: `KeyZ` confirms on VX and VX Ace but maps to the A button on
XP. `Enter` and `Space` confirm on all three engines. For this reason,
the built-in gamepad map uses `Enter` for the south button. If your
game replaces the Input module (Pokémon Essentials does), your
bindings win. Base your map on your bindings instead of on this table.

## Precedence

Touch layout, first match wins:

1. A layout profile the player pinned to your game
2. Your `touch` section
3. The player's default layout profile
4. Empo's defaults

Layout profiles are named layouts the player manages in Empo's
settings and can apply to any game. A profile's file uses this same
format, so players can share one as a single `controls.json`. Your
`touch` section outranks the player's default profile, but a profile
pinned to your game outranks your section. Empo's edit mode saves the
player's edits into profiles. The old per-game copy in `EmpoState/`
still imports, but Empo no longer writes it.

When your file provides layer 2, the Reset button in Empo's edit mode
returns players to it. The button label is then "Reset to game
default."

Screen placement is not part of this format. It belongs to the
player's layout profiles, so a game cannot set it. Your `touch`
section positions controls only.

Controller bindings merge per element. Later layers override earlier
ones:

1. Empo's built-in map
2. The player's global overrides (all games)
3. Your `bindings` section
4. The player's overrides for your game

Your file outranks a player's global preferences because you know your
game's scripts. The player keeps the last word for your specific game.
Design your map as the best default, and expect players to adjust it.

## Validation and debugging

Empo validates the whole file at load. One error rejects the entire
file. The game then falls back to the defaults, as if the file did not
exist. There is no partial application: players get either your exact
layout or Empo's, never a mix you did not test.

Two documented exceptions exist, both for forward compatibility with
future actions. An unknown action in `actionButtons` skips that one
button (W004). An unknown action in `bindings` keeps the entry but
makes it do nothing (W005). Both are warnings, and the rest of the
file loads.

A rejected file is loud on purpose. Empo writes every finding to the
game's log folder (`Logs/controls.json.log` inside the game's
container). Empo also shows a notice in the edit-controls screen:
"This game ships a controls.json with N errors." If a report says your
controls did not show up, ask a tester for that log line.

| Code | Meaning |
|---|---|
| V000 | Broken JSON, or a value of the wrong type |
| V001 | File exceeds 128 KiB |
| V002 | `version` missing or not `1` |
| V010 | Unknown key code (the message echoes the bad string) |
| V011 | Coordinate missing or outside 0.0 to 1.0 |
| V012 | Size or opacity out of range |
| V013 | More than 21 entries in `buttons` |
| V014 | `$action` in a normal touch button's `key` |
| V015 | More than 21 `buttons` + `actionButtons` combined in one orientation |
| V020 | Unknown binding source (not an element, not a key) |
| V023 | A controller element bound to another element |
| V021 | Superseded by W005 (older Empo versions still reject the file with it) |
| W001 | Neither `touch` nor `bindings` present (warning) |
| W002 | Label truncated to 8 characters (warning) |
| W003 | Two buttons share one key (warning) |
| W004 | Unknown action in `actionButtons`, so that button is skipped (warning) |
| W005 | Unknown action in `bindings`, so the binding stays but does nothing (warning) |
| W006 | Unknown `dpad` style, so the d-pad is drawn instead (warning) |
| W007 | Both `bindings` and `controller` are present, so `controller` is ignored (warning) |

Warnings never reject the file.

To catch errors before you ship, validate the file against the
[JSON Schema](https://github.com/mateo-m/empo-app/blob/main/docs/schemas/empo-controls.v1.schema.json). Any JSON-aware
editor or a validator like `ajv` works.

## Versioning

`version` is an integer, currently always `1`.

- New optional fields will arrive without a version bump. Old Empo
  versions ignore fields they do not know.
- An Empo that only knows version 1 ignores a `version: 2` file in
  full. Newer formats never half-apply.
- Version 1 files work forever. If a version 2 ever exists, every
  future Empo will read version 1 files exactly as this document
  describes. It is safe to ship a `controls.json` today.

Three compatibility notes:

- `actionButtons` needs Empo 0.6 or later. Older versions ignore the
  list and show the rest of your layout. Safe to ship.
- Key sources and the `bindings` name need Empo 0.6 or later. Write
  `controller` with element sources only if you must support 0.5.
- A `controller` entry bound to one of the new actions makes Empo
  0.5 and older reject the whole file (their V021 was a hard error).
  If you must support older versions, keep new actions out of your
  `bindings` section for now.

## Before you ship

1. Validate the file. With the `$schema` line, your editor flags
   errors as you type. Any JSON Schema validator works too. One
   minute.
2. Import the game in Empo and open the edit-controls screen. A broken
   file shows an error notice there. Details go to the game's
   `Logs/controls.json.log`. Five minutes.
3. If you ship a `bindings` section, connect a gamepad and press
   each remapped element once in-game. Five minutes.

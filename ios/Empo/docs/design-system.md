---
title: Design rules
description: The colors, type, spacing, materials, motion, and voice that the Empo app uses, written down so the app, the docs site, and the landing page match.
---

The tokens live in `ios/Empo/src/Design/Theme.swift`. The components live in the same
folder. This page records the rules the code encodes, so a new screen, a web page, or a
mockup can follow them without a read of the Swift.

## Brand

- **The mark** is a pixel sailboat, white on orange. The name comes from _emporos_, a
  traveler on someone else's ship. The mark is the app icon, the splash logo, the settings
  header, and the empty-state illustration. It is never recolored except to white or to the
  brand orange on a neutral surface.
- **The wordmark** is the word "Empo" in the system rounded face, bold, 40 pt on the splash
  and 28 pt in the settings header. Nothing else uses a display size.
- **The pattern** is a tile of six random 16 px pixel icons (circle, square, diamond, heart,
  star, plus, cube, sphere), white at 8% over the brand orange, scaled 5x, rotated -15
  degrees, and panned slowly. It appears on the splash and on the disclaimer. The app icon
  uses a halftone dot grid with the same intent.
- **Pixels are the motif.** The mark, the pattern, and the icon are all hard-edged pixel
  art. Rendering uses nearest-neighbor. Everything else in the interface is smooth system
  material. The contrast is the identity: pixel art content inside a modern iOS shell.

## Color

The app follows a 60-30-10 split. Sixty percent is the system neutral (backgrounds and
text). Thirty percent is warm tinted surfaces. Ten percent is the brand orange on the
actions and the active states.

| Token         | Light       | Dark        | Use                                            |
| ------------- | ----------- | ----------- | ---------------------------------------------- |
| `brand`       | `#FA8F29`   | `#FA8F29`   | Primary buttons, toggles, links, selected state |
| `surface`     | `#FFF7ED`   | `#29211A`   | Warm tinted cards and supporting surfaces       |
| `destructive` | `#E63D33`   | `#FF6159`   | Delete and other irreversible actions           |
| `success`     | `#33B859`   | `#59E680`   | Confirmed, done, recovered                      |
| `warning`     | `#E6B31A`   | `#FFD159`   | Needs attention, not broken                     |

Rules:

- The brand orange is a fixed RGB value. The system orange drifts yellow on inverted sheets.
- Text on brand orange is white. Secondary text on brand orange is white at 85% to 90%.
- Text over artwork is white with a text shadow, over a dark material scrim. The scrim is
  pinned to the dark scheme, so it stays dark in light mode.
- The player (toolbar, D-pad, buttons) pins the glass material to its dark variant. The game
  decides the backdrop, so the controls cannot depend on the system scheme.
- The docs site uses the same accent (`#fa8f29`) with a medium radius.

Opacity tokens, for foreground content over images or glass:

| Token        | Value | Use                                   |
| ------------ | ----- | ------------------------------------- |
| `textMuted`  | 0.7   | Secondary text and icons over images  |
| `border`     | 0.2   | Hairline rims and dividers            |
| `disabled`   | 0.4   | A disabled glass control              |
| `brandTint`  | 0.1   | Brand tint behind a secondary control |

Scrims that dim what is behind them: 0.3 light, 0.5 medium (a modal), 0.6 heavy.

## Type

- Use the system text styles first (`body`, `headline`, `caption`) so Dynamic Type works.
- The rounded design appears only on the wordmark, the settings header, and the disclaimer.
  It signals "Empo speaks" as opposed to "the system speaks".
- Monospaced appears only in the diagnostics overlay (13 pt medium rows, 14 pt bold title,
  17 pt bold FPS).
- Card titles are `caption` semibold, two lines maximum, with a 0.75 minimum scale. The
  engine name under the title is `caption2` at 70% opacity.
- Sheet titles are `title2` bold under a 48 pt brand-tinted symbol. Sheet body text is
  `subheadline` secondary. Fine print is `footnote` secondary.
- A small button label is `footnote` semibold.

## Spacing and shape

A 4-point grid. Pick by role, not by number.

| Token  | Points | Role                                    |
| ------ | ------ | --------------------------------------- |
| `xxs`  | 2      | Hairline gaps                           |
| `xs`   | 4      | Inline icon gaps, chip vertical padding |
| `sm`   | 6      | Inner padding of a small control        |
| `md`   | 8      | Inner padding of a card or a button     |
| `lg`   | 12     | Grid gutters, row spacing               |
| `xl`   | 16     | Section padding, screen-edge margin     |
| `_2xl` | 20     | Large button horizontal padding         |
| `_3xl` | 32     | Section breaks                          |
| `_4xl` | 40     | Empty state to primary action           |

Corner radii:

| Token   | Points | Use                                      |
| ------- | ------ | ---------------------------------------- |
| `xs`    | 4      | Inline badges                            |
| `sm`    | 8      | List artwork thumbnails                  |
| `md`    | 12     | Cards, sheet cards, grid artwork         |
| `lg`    | 16     | Hero card                                |
| `xl`    | 24     | Outer containers                         |
| `sheet` | 56     | The modal sheet panel only               |

Buttons, chips, and icon buttons are capsules or circles, never rounded rectangles.

Sizes:

- The minimum tap target is 44 pt. A 32 pt or 38 pt icon button extends its hit shape to 44.
- Toolbar and icon buttons are 32, 38, or 44 pt. The symbol is 42% of the frame.
- List artwork is 48 pt. Info artwork is 80 pt.
- Row icons are 24 pt. Placeholder icons are 36 pt. Empty-state icons are 48 pt.

## Materials and elevation

- Every control is Liquid Glass. Primary is glass with a full brand tint and white text.
  Secondary is glass with a 10% brand tint and brand text. Outline is plain glass with a
  quaternary hairline. Chips are glass with a 30% black scrim and white `caption2` text.
- Cards carry a two-layer shadow: a tight 1 pt layer at 5% to define the edge, and a 6 pt
  layer at 12% for elevation. Flatten the card first, or each layer draws once per child.
- Floating elements use an 8 pt shadow at 25%. Small icons over artwork use a 3 pt shadow
  at 50%. Text over artwork uses a 3 pt shadow at 70%.
- Bottom sheets sit on one opaque grouped surface. A sheet that floats over a running game
  uses the translucent material instead, so the game stays visible. See
  [Sheet design rules](sheet-design.md).

## Motion

Springs with no bounce, except where the element is meant to feel playful.

| Preset         | Curve                                  | Use                                        |
| -------------- | -------------------------------------- | ------------------------------------------ |
| `instant`      | ease-out 80 ms                         | D-pad arm highlight, slider snap           |
| `snappy`       | spring 180 ms, bounce 0                | Press, toggle, small state change          |
| `controlPress` | spring, response 0.2, damping 0.7      | Action button and D-pad press              |
| `bouncy`       | spring 250 ms, bounce 0.15             | Import button arc, hint banner entrance    |
| `standard`     | spring 300 ms, bounce 0                | List changes, layout shifts, navigation    |
| `gentle`       | spring 350 ms, bounce 0                | Background changes, slow reveals           |
| `slow`         | spring 500 ms, bounce 0                | Loading reveals, large layout shifts       |
| `emphasize`    | spring 800 ms, bounce 0                | Loading handoffs                           |
| `float`        | ease-in-out 2.4 s, repeat, autoreverse | Idle drift of the empty-state mark, ±3 pt  |
| `spinner`      | linear 1 s, repeat                     | The import ring                            |

Rules:

- A pressed control scales to 0.95. Cards and buttons use the same number.
- An element enters with opacity 0 to 1, a 12 pt rise, and often a blur from 6 to 10 pt
  down to 0. An element exits with the reverse: scale to 0.8, fade, and blur.
- A list reveals in a cascade. Items stagger by 40 ms. Sparse controls stagger by 60 ms
  after a 150 ms delay so the layout settles first.
- The empty state reveals icon, title, and subtitle 100 ms apart, then starts to float.
- The player toolbar dims to 30% after 3 s without a touch and returns to full on any touch.
- The splash exits with a blur to 10 pt, a scale to 0.8, and a fade. The disclaimer slides
  into the place the logo left.
- Pause shows a frozen frame of the game and animates that frame, because the SDL window
  cannot animate with SwiftUI. See [Pause and resume](pause-resume.md).

## Haptics

- Every button press fires a light impact when interface haptics are on.
- A larger state change fires a medium impact. A completed task fires the success
  notification.
- The on-screen game controls fire a light impact on engage, behind a separate setting, so
  a player can keep interface haptics and drop the buzz during play.

## Voice

The interface copy is short, first person where the author speaks, and honest about what
can go wrong.

- The disclaimer says "Here be dragons, or bugs!" and "I am a lone dev who builds this in
  my spare time."
- The empty library says "No Games Yet. Add your favorite RPG Maker games to get started!"
- The settings footer says "Made with ☕ by Grid."
- Alerts state the reason and the one action, and nothing else.
- Hints use the filled lightbulb and one sentence.

Use the same voice on the web. Headlines are plain statements of what Empo does. Warnings
give the condition first, then the instruction.

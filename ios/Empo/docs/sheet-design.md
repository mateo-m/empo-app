---
title: Sheet design rules
description: How Empo builds bottom sheets, so every sheet matches the system sheet language and the other sheets in the app.
---

How Empo builds bottom sheets. These rules keep every sheet
consistent with the system's own sheet language (welcome, What's
New, and activity-summary sheets) and with each other. Reference
implementations: `SaveRecoverySheet`, `ImageSourceSheet`, the
Build Info sheet in `SettingsView`, and `PlayerMoreSheet` for the
in-game exception.

## Build with the components

New sheets compose the vocabulary in `Design/Sheet.swift` instead
of hand-writing chrome:

```swift
StandardSheet(title: "Saves Recovered", emblem: "checkmark.seal") {
    SheetProse("What happened and why.")
    SheetCard { /* rows, SheetRowSeparator between them */ }
    SheetFootnote("The fine print.")
    SheetPrimaryButton("Done") { dismiss() }
}
```

`StandardSheet` owns the surface, title, intrinsic sizing, brand
tint, and the optional trailing toolbar action. The rules below
are the contract those components implement - and what remains
the sheet author's job: content, alignment inside rows, touch
targets, and haptics. Sheets over a running game pass
`surface: .material`.

## When to use a sheet

- Use a sheet when the user reads, chooses, or acts on structured
  content: option lists, summaries, per-item actions.
- Use an alert only for a short confirmation with at most two
  choices and no structure. If the content wants a list, artwork,
  or more than one action, it is a sheet.

## Surface

- The whole sheet is ONE surface. The failure this rule bans:
  painting `systemGroupedBackground` on the content stack alone,
  which ends at the content bounds and shows a second tone when
  the user pulls the sheet up.
- `StandardSheet` paints the grouped surface with
  `presentationBackground`. Native `List`/`Form` sheets
  (`LibrarySortSheet`, `GameSettingsView`) manage their own
  surface and need nothing.
- A full-bleed picker on the sheet's default surface
  (`ImportRootPickerSheet`) is also one surface and is fine.
- Cards inside a grouped sheet use
  `secondarySystemGroupedBackground` clipped to `Radius.md`
  (`SheetCard`).
- Exception: sheets that float over a running game
  (`PlayerMoreSheet`) keep the system's translucent material so
  the game stays visible. Do not paint those at all.

## Sizing

- `StandardSheet` sizes itself to its content, scrolls content
  taller than the screen, and keeps content pinned to the top
  when the user pulls the sheet past its detent. Sheets built
  outside the vocabulary use the `IntrinsicSheet` helpers
  directly.
- Browsing sheets with unbounded content (settings, game info)
  use standard detents instead.
- Always keep the drag indicator visible (the detent helper does
  this).

## Anatomy and alignment

Top to bottom, each zone optional except the action:

1. **Identity** - the title takes one of two shapes, never a mix:
   - No emblem: an inline navigation-bar title
     (activity-summary style - image sources, build info).
   - With an emblem: the title joins the 48pt brand-tinted
     symbol as ONE centered block at the top of the content
     (welcome-sheet style - pass `emblem:` to `StandardSheet`).
     A bar title plus a floating symbol reads as two competing
     anchors. Never split them.
2. **Body text** - `subheadline` secondary text, LEADING-aligned.
   Reading content is always leading. Only the identity block
   centers.
3. **Card** - rows in a `secondarySystemGroupedBackground` card.
   Rows are leading-aligned: leading thumbnail (44pt, `Radius.sm`),
   text column, then a trailing action
   (`SecondaryButtonStyle(size: .sm)`). Separate rows with a
   `Divider` indented past the thumbnail column
   (`Spacing.lg + 44 + Spacing.lg`).
4. **Footer** - `footnote` secondary text, leading-aligned.
5. **Primary action** - one full-width button at the bottom
   (`SheetPrimaryButton`). Destructive actions get their own card
   above it, never a red primary button. Multi-step pickers may
   confirm from the toolbar instead (`ImportRootPickerSheet`).
   That is the system's picker pattern, not a break of this rule.

## Touch targets

- Every tappable thing is at least 44pt tall.
- When a row carries one action, the WHOLE row is the button and
  the trailing element (chevron, "Files" link, checkmark) is
  decoration. Never park the only action in a small trailing
  pill: its target would sit under the minimum, and the row
  itself would be dead space.

## Metrics

- Outer padding: `Spacing.xl` on all sides.
- Between zones: `Spacing.xl`.
- Inside a text column: `Spacing.xxs`-`Spacing.md`.
- Row padding: `Spacing.lg` horizontal, `Spacing.md` vertical.

## Motion and feel

- Scale animation effort to frequency. Rare sheets (a one-time
  recovery) may add delight. Everyday sheets (sort, image
  sources) use the system transition and nothing else. Actions
  the user repeats often animate very little or not at all.
- Use the `Motion` tokens. Do not invent durations. UI motion
  stays at or under 300ms (`snappy`, `standard`). Only decorative
  movement runs longer. Entrances ease out, never ease in.
- Be slow where the user decides, fast where the system responds.
  A confirmation may take its time. Feedback for a tap must be
  immediate.
- The system sheet handles drag physics (interruption, velocity
  dismissal, edge damping). Do not re-implement or fight it, and
  keep the drag indicator visible.
- Haptics: row and selection actions give `Haptics.tap()`. A
  sheet that announces a rare, good outcome may play
  `Haptics.success()` once on presentation. Nothing else buzzes.
  All haptics route through `Haptics`, which respects the user's
  interface-haptics setting.
- Respect Reduce Motion: prefer the system transitions (which
  already adapt) and keep any custom motion opacity-based when
  the setting is on.

## Behavior

- Tint the sheet `.brand`.
- One-time surfaces (recovery sheet, duplicate-games notice)
  wait for the splash screen to finish before presenting. A sheet
  sliding over the splash is noise, and the user must see the
  library the sheet talks about.
- A one-time sheet treats ANY dismissal (button or swipe) as
  acknowledgment. Derive `isPresented` from the pending state and
  clear that state in the binding's setter. Never rely on the
  button alone.
- Keep presentation logic out of large views: a sheet owns its
  loading, derived state, and dismissal in a self-contained
  `ViewModifier` (`SaveRecoveryPresentation` is the model), and
  the presenting view attaches one modifier line.

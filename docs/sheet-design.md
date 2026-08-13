# Sheet design rules

How Empo builds bottom sheets. These rules keep every sheet
consistent with the system's own sheet language (welcome, What's
New, and activity-summary sheets) and with each other. Reference
implementations: `SaveRecoverySheet`, `ImageSourceSheet`, the
Build Info sheet in `SettingsView`, and `PlayerMoreSheet` for the
in-game exception.

## When to use a sheet

- Use a sheet when the user reads, chooses, or acts on structured
  content: option lists, summaries, per-item actions.
- Use an alert only for a short confirmation with at most two
  choices and no structure. If the content wants a list, artwork,
  or more than one action, it is a sheet.

## Surface

- Paint the whole sheet as ONE surface:
  `.presentationBackground(Color(.systemGroupedBackground))` on
  the sheet's outermost view.
- Never paint `systemGroupedBackground` on the content stack
  alone. The color ends at the content bounds and a pull-up
  reveals a second tone above it.
- Cards inside the sheet use `secondarySystemGroupedBackground`
  clipped to `Radius.md`.
- Exception: sheets that float over a running game
  (`PlayerMoreSheet`) keep the system's translucent material so
  the game stays visible. Do not paint those at all.

## Sizing

- Content-sized sheets use the `IntrinsicSheet` helpers:
  `.intrinsicSheetContent(measuredHeight:)` on the content,
  `.intrinsicSheetDetent(measuredHeight:)` on the outer view.
- Browsing sheets with unbounded content (settings, game info)
  use standard detents instead.
- Always keep the drag indicator visible (the detent helper does
  this).

## Anatomy and alignment

Top to bottom, each zone optional except the action:

1. **Title** - inline navigation title, centered by the system.
2. **Emblem** - one tinted SF Symbol, 48pt, `Color.brand`,
   CENTERED. The emblem is the sheet's identity mark, not reading
   content. Give it `Spacing.md` extra top padding so it reads as
   its own zone.
3. **Prose** - `subheadline` secondary text, LEADING-aligned.
   Reading content is always leading; only the emblem centers.
4. **Card** - rows in a `secondarySystemGroupedBackground` card.
   Rows are leading-aligned: leading thumbnail (44pt, `Radius.sm`),
   text column, then a trailing action
   (`SecondaryButtonStyle(size: .sm)`). Separate rows with a
   `Divider` indented past the thumbnail column
   (`Spacing.lg + 44 + Spacing.lg`).
5. **Footer** - `footnote` secondary text, leading-aligned.
6. **Primary action** - one full-width button at the bottom:
   `PrimaryButtonStyle()` with the label stretched
   (`Text(...).frame(maxWidth: .infinity)`). Destructive actions
   get their own card above it, never a red primary button.

## Metrics

- Outer padding: `Spacing.xl` on all sides.
- Between zones: `Spacing.xl`.
- Inside a text column: `Spacing.xxs`-`Spacing.md`.
- Row padding: `Spacing.lg` horizontal, `Spacing.md` vertical.

## Behavior

- Tint the sheet `.brand`.
- A one-time sheet treats ANY dismissal (button or swipe) as
  acknowledgment. Derive `isPresented` from the pending state and
  clear that state in the binding's setter; never rely on the
  button alone.
- Keep presentation logic out of large views: a sheet owns its
  loading, derived state, and dismissal in a self-contained
  `ViewModifier` (`SaveRecoveryPresentation` is the model), and
  the presenting view attaches one modifier line.

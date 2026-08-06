import SwiftUI

/// Top-right toolbar overlay shown during play. It stays a standalone
/// View so PlayerView can focus on orchestration (state, lifecycle,
/// alerts) while toolbar assembly + edit-mode variant live here.

struct PlayerToolbar: View {
    let isPortrait: Bool
    let safeArea: EdgeInsets
    let geoSize: CGSize
    let controlsHidden: Bool
    let toolbarOpacity: Double
    let onToggleKeyboard: () -> Void
    let onToggleEditMode: () -> Void
    let onToggleHideControls: () -> Void
    let onShowMore: () -> Void
    /// `false` when `PlayerMoreSheet` would render no rows given
    /// the current settings + per-game state - typically when the
    /// user has disabled cheats, fast-forward, pause, and the
    /// diagnostics overlay. We hide the Menu button rather than
    /// surface an empty sheet.
    let menuVisible: Bool
    let onResetIdleTimer: () -> Void

    var body: some View {
        let btnSize = IconButtonSize.sm.points
        let gap: CGFloat = isPortrait ? Spacing.sm : Spacing.md

        let buttons = toolbarButtons()
        let toolbarPosition = ControlsZone.toolbarOrigin(
            safeArea: safeArea, geoSize: geoSize, btnSize: btnSize, gap: gap, count: CGFloat(buttons.count))

        HStack(spacing: gap) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, entry in
                IconButton(
                    entry.icon,
                    style: .outline,
                    size: .sm,
                    tint: entry.tint
                ) {
                    onResetIdleTimer()
                    entry.action()
                }
                .accessibilityLabel(entry.label)
            }
        }
        // Pin the Liquid Glass material to the dark variant so the
        // toolbar matches the on-screen controls (D-pad, action
        // buttons) and doesn't shift appearance with the system
        // color scheme or the backdrop brightness of the game.
        .darkGlass()
        // Measure the region BEFORE .position, which expands to
        // the full proposed space.
        .chromeHitRegion("toolbar")
        .opacity(toolbarOpacity)
        .position(toolbarPosition)
    }

    /// Build the toolbar entries imperatively so the `Menu` cap
    /// can be appended only when `menuVisible` is true. Inlining
    /// this in `body` collides with SwiftUI's ViewBuilder, which
    /// disallows non-View `if` branches at expression scope.
    private func toolbarButtons() -> [ToolbarEntry] {
        var entries: [ToolbarEntry] = [
            ToolbarEntry(icon: "keyboard", label: "Toggle keyboard", tint: .white, action: onToggleKeyboard),
            // square.and.pencil reads as "edit this region" which
            // fits the controls-edit mode better than a generic
            // gear/settings.
            ToolbarEntry(
                icon: "square.and.pencil", label: "Edit controls", tint: .white, action: onToggleEditMode),
            ToolbarEntry(
                icon: controlsHidden ? "eye.slash.fill" : "eye.fill",
                label: controlsHidden ? "Show controls" : "Hide controls",
                tint: .white,
                action: onToggleHideControls
            ),
        ]
        if menuVisible {
            // ellipsis.circle is the iOS-idiomatic "more options"
            // cue. It opens PlayerMoreSheet for cheats / fast-forward
            // / diagnostics-overlay / pause. It stays hidden when
            // none of those rows would render.
            entries.append(
                ToolbarEntry(icon: "ellipsis.circle", label: "Menu", tint: .white, action: onShowMore))
        }
        return entries
    }

    private struct ToolbarEntry {
        let icon: String
        let label: String
        let tint: Color?
        let action: () -> Void
    }
}

struct PlayerEditToolbar: View {
    let controlsMinY: CGFloat
    let safeArea: EdgeInsets
    let geoSize: CGSize
    var layout: ControlsLayout
    @Binding var showAddSheet: Bool
    @Binding var showResetConfirm: Bool
    let onDone: () -> Void

    /// Half-heights for `.position` anchoring, same idiom as
    /// `ControlsZone.editToolbarHalfHeight`: caption2 + 2x4 padding
    /// for the pill; footnote capsule + 2x4 container padding for
    /// the row.
    private static let bannerHalfHeight: CGFloat = 11
    private static let actionsHalfHeight: CGFloat = IconButtonSize.sm.points / 2
    /// The pill's gap above the zone border equals the action row's
    /// gap below it (user ruling: symmetric around the border).
    private static let borderGap: CGFloat = Spacing.md

    var body: some View {
        // Anchor both pieces to the controls-zone border, not the
        // game rect: the pill floats above the border line by the
        // same distance the action row sits below it.
        let zoneTop = ControlsZone.bounds(
            controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geoSize
        ).minY

        ZStack {
            // Blast-radius banner: a pinned profile's edits reach
            // every game using it; ambient edits mint a new profile.
            // Its own small pill, so the button capsule stays clean.
            Text(editBannerText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .glassEffect(.regular, in: .capsule)
                .position(
                    x: geoSize.width / 2,
                    y: max(
                        safeArea.top + Self.bannerHalfHeight,
                        zoneTop - Self.borderGap - Self.bannerHalfHeight)
                )

            actionsRow
                .position(
                    x: geoSize.width / 2,
                    y: zoneTop + Self.borderGap + Self.actionsHalfHeight)
        }
    }

    /// Four actions: symbols, per the HIG rule for bars past three
    /// buttons. The tools are the SAME circular glass buttons as
    /// the play toolbar, so edit mode reads as a variant of it;
    /// Done keeps the tinted capsule and its shape alone marks it
    /// as the primary action. No chromeHitRegion: PlayerEditToolbar
    /// stays mounted at opacity 0 during play (its region would
    /// cover center screen), and edit mode already publishes a
    /// full-screen region.
    private var actionsRow: some View {
        HStack(spacing: Spacing.md) {
            IconButton("plus", style: .outline, size: .sm, tint: .white) {
                showAddSheet = true
            }
            .accessibilityLabel("Add button")

            IconButton(
                "arrow.uturn.backward", style: .outline, size: .sm,
                tint: .white.opacity(layout.canUndo ? 1 : Alpha.disabled)
            ) {
                layout.undoLastEdit()
            }
            .accessibilityLabel("Undo layout change")
            .disabled(!layout.canUndo)

            IconButton("arrow.counterclockwise", style: .outline, size: .sm, tint: .brand) {
                showResetConfirm = true
            }
            .accessibilityLabel("Reset layout")

            Button {
                onDone()
            } label: {
                Text("Done")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.lg)
                    .frame(height: IconButtonSize.sm.points)
                    .glassEffect(.regular.tint(.success).interactive(), in: .capsule)
            }
        }
        // Pin the glass to the dark variant, matching the play
        // toolbar and the on-screen controls.
        .darkGlass()
    }

    private var editBannerText: String {
        switch layout.provenance {
        case .pinnedProfile(let name):
            return "Editing \(name). Changes apply to every game that uses it."
        case .gameLayout, .defaultProfile, .builtin:
            return "Edits save as a new profile"
        }
    }
}

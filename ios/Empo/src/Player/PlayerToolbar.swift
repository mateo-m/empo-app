import SwiftUI

/// Top-right toolbar overlay shown during play. Kept as a standalone
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
            // cue; opens PlayerMoreSheet for cheats / fast-forward
            // / diagnostics-overlay / pause. Hidden when none of
            // those rows would render.
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
    let isPortrait: Bool
    let gameRect: CGRect
    let safeArea: EdgeInsets
    let geoSize: CGSize
    @Binding var showAddSheet: Bool
    @Binding var showResetConfirm: Bool
    let onDone: () -> Void

    var body: some View {
        let overlay = ControlsZone.useOverlayLayout(
            isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoHeight: geoSize.height)
        let yPos: CGFloat =
            isPortrait && gameRect.height > 0 && !overlay
            ? gameRect.origin.y + gameRect.height + ControlsZone.toolbarGap
                + ControlsZone.editToolbarHalfHeight
            : max(safeArea.top, ControlsZone.minLandscapeInset) + ControlsZone.toolbarEdgePad
                + ControlsZone.editToolbarHalfHeight

        HStack(spacing: Spacing.xl) {
            Button("+ Add") { showAddSheet = true }
                .accessibilityLabel("Add button")
                .foregroundStyle(.white)
                .font(.footnote.weight(.semibold))
            Button("Reset") { showResetConfirm = true }
                .foregroundStyle(.brand)
                .font(.footnote.weight(.semibold))
            Button("Done") { onDone() }
                .foregroundStyle(.success)
                .font(.footnote.weight(.bold))
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .background(Color.black.opacity(Scrim.heavy))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .position(x: geoSize.width / 2, y: yPos)
    }
}

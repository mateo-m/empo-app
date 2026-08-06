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
    let isPortrait: Bool
    let gameRect: CGRect
    let safeArea: EdgeInsets
    let geoSize: CGSize
    var layout: ControlsLayout
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

        VStack(spacing: Spacing.xs) {
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
                // Nudged up for a little more air above the button
                // row (user request: a few pixels).
                .offset(y: -3)

            HStack(spacing: Spacing.lg) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityLabel("Add button")
                .foregroundStyle(.white)

                Button {
                    layout.undoLastEdit()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .accessibilityLabel("Undo layout change")
                .foregroundStyle(.white.opacity(layout.canUndo ? 1 : Alpha.disabled))
                .disabled(!layout.canUndo)

                Button {
                    showResetConfirm = true
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .foregroundStyle(.brand)

                // Done is the primary action of the whole mode: a
                // small tinted capsule inside the bar makes it read
                // as such (the iOS 26 prominent-toolbar-button
                // idiom).
                Button {
                    onDone()
                } label: {
                    Text("Done")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xs)
                        .glassEffect(.regular.tint(.success).interactive(), in: .capsule)
                }
            }
            .font(.footnote.weight(.semibold))
            // Concentric capsules: the Done capsule's gap to the
            // container edge must match its vertical gap, so the
            // trailing inset equals the vertical inset. The leading
            // side keeps room for the plain text buttons.
            .padding(.leading, Spacing.lg)
            .padding(.trailing, Spacing.xs)
            .padding(.vertical, Spacing.xs)
            .glassEffect(.regular, in: .capsule)
        }
        // Pin the glass to the dark variant, matching the play
        // toolbar and the on-screen controls.
        .darkGlass()
        // No chromeHitRegion here: PlayerEditToolbar stays mounted at
        // opacity 0 during play (its region would cover center screen),
        // and edit mode already publishes a full-screen region.
        .position(x: geoSize.width / 2, y: yPos)
    }

    private var editBannerText: String {
        switch layout.provenance {
        case .pinnedProfile(let name):
            return "Editing profile \(name) — applies to every game using it"
        case .gameLayout, .defaultProfile, .builtin:
            return "Edits save as a new profile"
        }
    }
}

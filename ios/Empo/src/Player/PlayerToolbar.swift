// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct PlayerToolbar: View {
    let isPortrait: Bool
    let safeArea: EdgeInsets
    let geoSize: CGSize
    let controlsHidden: Bool
    let keyboardShown: Bool
    let toolbarOpacity: Double
    let onToggleKeyboard: () -> Void
    let onToggleEditMode: () -> Void
    let onToggleHideControls: () -> Void
    let onShowMore: () -> Void
    let onResetIdleTimer: () -> Void

    private enum Entry: CaseIterable {
        case keyboard, editControls, hideControls, more
    }

    static func placement(
        isPortrait: Bool, safeArea: EdgeInsets, geoSize: CGSize
    ) -> ControlsZone.ToolbarPlacement {
        ControlsZone.toolbarPlacement(
            safeArea: safeArea, geoSize: geoSize, occluded: AppWindow.occludedRects,
            btnSize: IconButtonSize.sm.points, gap: gap(isPortrait: isPortrait),
            count: CGFloat(Entry.allCases.count))
    }

    private static func gap(isPortrait: Bool) -> CGFloat { isPortrait ? Spacing.sm : Spacing.md }

    var body: some View {
        let gap = Self.gap(isPortrait: isPortrait)
        let buttons = toolbarButtons()
        let placement = Self.placement(isPortrait: isPortrait, safeArea: safeArea, geoSize: geoSize)
        let stack =
            placement.isVertical
            ? AnyLayout(VStackLayout(spacing: gap)) : AnyLayout(HStackLayout(spacing: gap))

        let ordered = placement.isVertical ? Array(buttons.reversed()) : buttons

        stack {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, entry in
                IconButton(
                    entry.icon,
                    label: entry.label,
                    style: .outline,
                    size: .sm,
                    tint: entry.tint
                ) {
                    onResetIdleTimer()
                    entry.action()
                }
            }
        }
        .darkGlass()
        // `.position` fills the full proposed space, so measure the
        // region before it.
        .chromeHitRegion("toolbar")
        .opacity(toolbarOpacity)
        .position(placement.center)
    }

    private func toolbarButtons() -> [ToolbarEntry] {
        Entry.allCases.map { entry in
            switch entry {
            case .keyboard:
                ToolbarEntry(
                    icon: "keyboard",
                    label: keyboardShown ? "Hide keyboard" : "Show keyboard",
                    tint: .white,
                    action: onToggleKeyboard)
            case .editControls:
                ToolbarEntry(
                    icon: "square.and.pencil", label: "Edit controls", tint: .white, action: onToggleEditMode)
            case .hideControls:
                ToolbarEntry(
                    icon: controlsHidden ? "eye.slash.fill" : "eye.fill",
                    label: controlsHidden ? "Show controls" : "Hide controls",
                    tint: .white,
                    action: onToggleHideControls)
            case .more:
                ToolbarEntry(
                    icon: "ellipsis.circle", label: "More options", tint: .white, action: onShowMore)
            }
        }
    }

    private struct ToolbarEntry {
        let icon: String
        let label: LocalizedStringResource
        let tint: Color?
        let action: () -> Void
    }
}

struct PlayerEditToolbar: View {
    let controlsMinY: CGFloat
    let safeArea: EdgeInsets
    let geoSize: CGSize
    var layout: ControlsLayout
    @Binding var editDialog: ControlsEditDialog?
    let onDone: () -> Void

    @AppStorage(DefaultsKey.controlsEditSnapToGrid) private var snapToGrid = false

    /// Used until `onGeometryChange` gives the real sizes.
    private static let bannerHalfHeightFallback: CGFloat = 11
    private static let actionsHalfHeightFallback: CGFloat = IconButtonSize.sm.points / 2
    /// The gap of the banner above the zone border, and of the action
    /// row below it.
    private static let borderGap: CGFloat = Spacing.md

    private var bannerHalfHeight: CGFloat {
        bannerFrame.height > 0 ? bannerFrame.height / 2 : Self.bannerHalfHeightFallback
    }
    private var actionsHalfHeight: CGFloat {
        actionsFrame.height > 0 ? actionsFrame.height / 2 : Self.actionsHalfHeightFallback
    }

    var body: some View {
        // A crushed zone has space only for the tallest control. Then
        // both pieces go above the border.
        let zoneBounds = ControlsZone.bounds(
            controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geoSize)
        let zoneTop = zoneBounds.minY
        // The row below the border, and the same height again as a
        // gap above the tallest control.
        let actionsRowHeight = actionsHalfHeight * 2
        let headerRoom = actionsRowHeight * 2
        let crushed = zoneBounds.height < layout.requiredEditZoneHeight + headerRoom
        let actionsY =
            crushed
            ? zoneTop - Self.borderGap - actionsHalfHeight
            : zoneTop + Self.borderGap + actionsHalfHeight
        let bannerY =
            crushed
            ? actionsY - actionsHalfHeight - Spacing.xs - bannerHalfHeight
            : zoneTop - Self.borderGap - bannerHalfHeight

        ZStack {
            Text(editBannerText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .glassEffect(.regular, in: .capsule)
                .onGeometryChange(
                    for: CGRect.self, of: { $0.frame(in: .global) },
                    action: {
                        bannerFrame = $0
                        publishChromeFrames()
                    }
                )
                .position(
                    x: geoSize.width / 2,
                    y: max(safeArea.top + bannerHalfHeight, bannerY)
                )

            actionsRow
                .onGeometryChange(
                    for: CGRect.self, of: { $0.frame(in: .global) },
                    action: {
                        actionsFrame = $0
                        publishChromeFrames()
                    }
                )
                .position(x: geoSize.width / 2, y: actionsY)
        }
        // The banner is outside the dark glass of the action row.
        .darkGlass()
        .animation(.easeInOut(duration: 0.2), value: crushed)
    }

    @State private var bannerFrame: CGRect = .zero
    @State private var actionsFrame: CGRect = .zero

    /// The header pieces are walls for control drags, so a control
    /// cannot stop under them.
    private func publishChromeFrames() {
        layout.editChromeFrames = [bannerFrame, actionsFrame].filter { !$0.isEmpty }
    }

    /// No chromeHitRegion: this view stays in the tree at opacity 0
    /// during play, so its region would cover the center of the
    /// screen. Edit mode publishes a full-screen region.
    private var actionsRow: some View {
        HStack(spacing: Spacing.md) {
            IconButton("plus", label: "Add button", style: .outline, size: .sm, tint: .white) {
                editDialog = .addButton
            }

            IconButton(
                "arrow.uturn.backward", label: "Undo layout change", style: .outline, size: .sm,
                tint: .white.opacity(layout.canUndo ? 1 : Alpha.disabled)
            ) {
                layout.undoLastEdit()
            }
            .disabled(!layout.canUndo)

            IconButton(
                "grid", label: "Snap to grid", style: .outline, size: .sm,
                tint: snapToGrid ? .brand : .white
            ) {
                layout.toggleSnapToGrid(
                    in: ControlsLayout.EditGeometry(
                        geoSize: geoSize, safeArea: safeArea, controlsMinY: controlsMinY))
            }
            .accessibilityValue(
                snapToGrid
                    ? Text("On", comment: "Spoken state of a switch.")
                    : Text("Off", comment: "Spoken state of a switch."))

            IconButton(
                "arrow.counterclockwise", label: "Reset layout", style: .outline, size: .sm, tint: .brand
            ) {
                editDialog = .resetConfirm
            }

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
        .darkGlass()
    }

    private var editBannerText: LocalizedStringResource {
        switch layout.provenance {
        case .pinnedProfile(let name):
            return "Editing \(name). Changes apply to every game that uses it."
        case .gameLayout, .defaultProfile, .builtin:
            return "Your edits will create a new profile."
        }
    }
}

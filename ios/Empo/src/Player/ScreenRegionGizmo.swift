// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

struct ScreenRegionGizmo: View {
    static let moveAnimation = Animation.easeInOut(duration: 0.25)

    let canvas: ScreenCanvas
    let allowedRect: CGRect
    let baseRect: CGRect
    let onDragBegan: () -> Void
    let onDragChanged: (ScreenRegion) -> Void
    let onDragEnded: (ScreenRegion) -> Void
    /// Rides into every region the callbacks emit, so a drag cannot
    /// strip the choice the overlay toggle just made.
    var overlayOn: Bool = false

    @State private var draft: CGRect?
    @State private var anchorRect: CGRect?
    /// A second finger cannot change the anchor or end the drag.
    @State private var dragOwner: DragHandle?

    private var rect: CGRect { draft ?? baseRect }
    private var minW: CGFloat { canvas.size.width * ScreenRegionGizmo.minFraction }
    private var minH: CGFloat { canvas.size.height * ScreenRegionGizmo.minFraction }
    private static let minFraction = CGFloat(ScreenRegionFile.minFraction)

    private enum DragHandle: Equatable {
        case move
        case corner(Corner)
    }

    var body: some View {
        surfaces
    }

    /// Shrinks the anchor into `allowedRect`. A stored rect can break
    /// the limits after a restore from another device, or after the
    /// controls grow. Without the shrink, the clamps invert.
    private func claimDrag(owner: DragHandle) -> Bool {
        if anchorRect == nil {
            anchorRect = rect.kept(inside: allowedRect)
            dragOwner = owner
            onDragBegan()
        }
        return dragOwner == owner
    }

    private var surfaces: some View {
        ZStack {
            ZStack {
                Rectangle().fill(Color.brand.opacity(0.06))
                GizmoOutline()
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle())
            .editDrag(
                minimumDistance: 2, onChanged: moveChanged,
                onFinished: { finishDrag(owner: .move) }
            )
            .accessibilityLabel("Game screen position")
            .accessibilityHint("Drag to move the game screen")

            ForEach(Corner.allCases, id: \.self) { corner in
                CornerGrabber()
                    .stroke(
                        Color.brand,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: Self.grabberSide, height: Self.grabberSide)
                    .rotationEffect(.degrees(corner.bracketRotation))
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .position(corner.point(in: rect, inset: Self.grabberSide / 2 + 2))
                    .allowsHitTesting(false)
                Color.clear
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .position(corner.point(in: rect, inset: 16))
                    .editDrag(
                        minimumDistance: 2, onChanged: { resizeChanged($0, corner: corner) },
                        onFinished: { finishDrag(owner: .corner(corner)) }
                    )
                    .accessibilityLabel(corner.accessibilityLabel)
            }
        }
    }

    private static let grabberSide: CGFloat = 22

    private func moveChanged(_ value: DragGesture.Value) {
        guard claimDrag(owner: .move), let anchor = anchorRect else { return }
        let moved = anchor.offsetBy(
            dx: value.translation.width, dy: value.translation.height
        ).kept(inside: allowedRect)
        draft = moved
        onDragChanged(canvas.region(for: moved, overlay: overlayOn))
    }

    private func resizeChanged(_ value: DragGesture.Value, corner: Corner) {
        guard claimDrag(owner: .corner(corner)), let anchor = anchorRect
        else { return }
        var minX = anchor.minX
        var minY = anchor.minY
        var maxX = anchor.maxX
        var maxY = anchor.maxY
        switch corner {
        case .topLeft:
            minX += value.translation.width
            minY += value.translation.height
        case .topRight:
            maxX += value.translation.width
            minY += value.translation.height
        case .bottomLeft:
            minX += value.translation.width
            maxY += value.translation.height
        case .bottomRight:
            maxX += value.translation.width
            maxY += value.translation.height
        }
        // Bounds clamp first, then the minimum size pushes
        // the MOVING edges back inward.
        minX = max(allowedRect.minX, minX)
        minY = max(allowedRect.minY, minY)
        maxX = min(allowedRect.maxX, maxX)
        maxY = min(allowedRect.maxY, maxY)
        switch corner {
        case .topLeft:
            minX = min(minX, maxX - minW)
            minY = min(minY, maxY - minH)
        case .topRight:
            maxX = max(maxX, minX + minW)
            minY = min(minY, maxY - minH)
        case .bottomLeft:
            minX = min(minX, maxX - minW)
            maxY = max(maxY, minY + minH)
        case .bottomRight:
            maxX = max(maxX, minX + minW)
            maxY = max(maxY, minY + minH)
        }
        let resized = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        draft = resized
        onDragChanged(canvas.region(for: resized, overlay: overlayOn))
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var accessibilityLabel: LocalizedStringResource {
            switch self {
            case .topLeft: "Resize game screen, top left corner"
            case .topRight: "Resize game screen, top right corner"
            case .bottomLeft: "Resize game screen, bottom left corner"
            case .bottomRight: "Resize game screen, bottom right corner"
            }
        }

        /// Rotation that maps the bottom-right bracket path onto
        /// this corner (positive degrees turn clockwise on screen).
        var bracketRotation: Double {
            switch self {
            case .bottomRight: 0
            case .bottomLeft: 90
            case .topLeft: 180
            case .topRight: 270
            }
        }

        func point(in rect: CGRect, inset: CGFloat) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX + inset, y: rect.minY + inset)
            case .topRight: CGPoint(x: rect.maxX - inset, y: rect.minY + inset)
            case .bottomLeft: CGPoint(x: rect.minX + inset, y: rect.maxY - inset)
            case .bottomRight: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset)
            }
        }
    }

    private func finishDrag(owner: DragHandle) {
        guard dragOwner == owner else { return }
        if let draft {
            onDragEnded(canvas.region(for: draft, overlay: overlayOn))
        }
        anchorRect = nil
        draft = nil
        dragOwner = nil
    }
}

/// The player draws the chips above the controls overlay and the
/// gizmo below it, so they are two views.
struct ScreenRegionChips: View {
    let rect: CGRect
    let showsReset: Bool
    let onReset: () -> Void
    var overlayOn: Bool = false
    var onToggleOverlay: (() -> Void)?

    /// The chips stack down from the top edge of the region, one row
    /// for each chip.
    private func chipY(row: Int) -> CGFloat {
        rect.minY + 14 + 30 * CGFloat(row)
    }

    var body: some View {
        ZStack {
            Text("Screen")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.brand)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 2)
                .glassEffect(.regular, in: .capsule)
                .position(x: rect.midX, y: chipY(row: 0))
                .allowsHitTesting(false)

            if showsReset {
                Button {
                    onReset()
                } label: {
                    Label("Reset screen", systemImage: "arrow.counterclockwise")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .foregroundStyle(.white)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                // Top area, below the "Screen" label: the bottom
                // corner belongs to the resize grabber, and at the
                // minimum region size a bottom chip would overlap it.
                .position(x: rect.midX, y: chipY(row: 1))
                .accessibilityLabel("Reset screen to automatic placement")
            }

            if let onToggleOverlay {
                Button {
                    onToggleOverlay()
                } label: {
                    Label(
                        "Controls over game",
                        systemImage: overlayOn
                            ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .foregroundStyle(overlayOn ? Color.brand : .white)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .position(x: rect.midX, y: chipY(row: showsReset ? 2 : 1))
                .accessibilityLabel("Controls over game")
                .accessibilityValue(
                    overlayOn
                        ? Text("On", comment: "Spoken state of a switch.")
                        : Text("Off", comment: "Spoken state of a switch."))
            }
        }
        .darkGlass()
    }
}

private struct CornerGrabber: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Each edge starts and ends with a half dash, so all four corners
/// look the same. A plain dashed stroke starts its pattern at one
/// corner only.
private struct GizmoOutline: View {
    private static let lineWidth: CGFloat = 2
    private static let dashUnit: CGFloat = 8
    private static let gapUnit: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            let inset = Self.lineWidth / 2
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            guard frame.width > 8, frame.height > 8 else {
                context.stroke(
                    Path(frame), with: .color(.brand), lineWidth: Self.lineWidth)
                return
            }

            // Half-dash at both ends: the sequence half-dash, gap,
            // dash, ..., gap, half-dash spans (n+1) x (dash+gap)
            // exactly, so scale the pattern to a whole cycle count.
            func dashedLine(from: CGPoint, to: CGPoint) {
                let length = hypot(to.x - from.x, to.y - from.y)
                guard length > 1 else { return }
                let unit = Self.dashUnit + Self.gapUnit
                let cycles = max(1, (length / unit).rounded())
                let scale = length / (cycles * unit)
                let dash = Self.dashUnit * scale
                let gap = Self.gapUnit * scale
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(
                    path, with: .color(.brand),
                    style: StrokeStyle(
                        lineWidth: Self.lineWidth, dash: [dash, gap],
                        dashPhase: dash / 2))
            }
            dashedLine(
                from: CGPoint(x: frame.minX, y: frame.minY),
                to: CGPoint(x: frame.maxX, y: frame.minY))
            dashedLine(
                from: CGPoint(x: frame.maxX, y: frame.minY),
                to: CGPoint(x: frame.maxX, y: frame.maxY))
            dashedLine(
                from: CGPoint(x: frame.maxX, y: frame.maxY),
                to: CGPoint(x: frame.minX, y: frame.maxY))
            dashedLine(
                from: CGPoint(x: frame.minX, y: frame.maxY),
                to: CGPoint(x: frame.minX, y: frame.minY))
        }
        .allowsHitTesting(false)
    }
}

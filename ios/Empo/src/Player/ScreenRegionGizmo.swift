import GameProbe
import SwiftUI

/// Edit-mode drag/resize gizmo for the screen region. Pure
/// geometry: the parent supplies the rect to show and receives
/// fraction regions through callbacks; ControlsLayout and the
/// bridge applier stay in the parent's hands, so the same gizmo
/// works in the player and on the profile editor's mock canvas.
struct ScreenRegionGizmo: View {
    let canvasSize: CGSize
    /// The rect to draw when no drag is in flight, in canvas points.
    /// The parent derives it from the pending edit, the resolved
    /// region, or the automatic placement.
    let baseRect: CGRect
    /// Shows the "Reset screen" chip: an entry or a pending
    /// non-auto edit exists for this orientation.
    let showsReset: Bool
    let onDragBegan: () -> Void
    let onDragChanged: (ScreenRegion) -> Void
    let onDragEnded: (ScreenRegion) -> Void
    let onReset: () -> Void

    @State private var draft: CGRect?
    @State private var anchorRect: CGRect?

    private var rect: CGRect { draft ?? baseRect }
    private var minW: CGFloat { canvasSize.width * ScreenRegionGizmo.minFraction }
    private var minH: CGFloat { canvasSize.height * ScreenRegionGizmo.minFraction }
    private static let minFraction = CGFloat(ScreenRegionFile.minFraction)
    private static let handleSize: CGFloat = 28

    var body: some View {
        ZStack {
            ZStack {
                Rectangle().fill(Color.brand.opacity(0.06))
                GizmoOutline()
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle())
            .gesture(moveGesture)
            .accessibilityLabel("Game screen position")
            .accessibilityHint("Drag to move the game picture")

            Text("Screen")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.brand)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 2)
                .background(Color.black.opacity(Scrim.heavy))
                .clipShape(Capsule())
                .position(x: rect.midX, y: rect.minY + 14)
                .allowsHitTesting(false)

            // Corner resize handle.
            Circle()
                .fill(Color.brand)
                .overlay(
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                )
                .frame(width: Self.handleSize, height: Self.handleSize)
                .position(x: rect.maxX, y: rect.maxY)
                .gesture(resizeGesture)
                .accessibilityLabel("Resize game screen")

            if showsReset {
                Button {
                    onReset()
                } label: {
                    Label("Reset screen", systemImage: "arrow.counterclockwise")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(Color.black.opacity(Scrim.heavy))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                // Top area, below the "Screen" label: the bottom
                // corner belongs to the resize handle, and at the
                // minimum region size a bottom chip would overlap it.
                .position(x: rect.midX, y: rect.minY + 44)
                .accessibilityLabel("Reset screen to automatic placement")
            }
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if anchorRect == nil {
                    anchorRect = rect
                    onDragBegan()
                }
                guard let anchor = anchorRect else { return }
                var moved = anchor.offsetBy(
                    dx: value.translation.width, dy: value.translation.height)
                moved.origin.x = min(max(0, moved.origin.x), canvasSize.width - moved.width)
                moved.origin.y = min(max(0, moved.origin.y), canvasSize.height - moved.height)
                draft = moved
                onDragChanged(region(from: moved))
            }
            .onEnded { _ in finishDrag() }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if anchorRect == nil {
                    anchorRect = rect
                    onDragBegan()
                }
                guard let anchor = anchorRect else { return }
                var resized = anchor
                resized.size.width = min(
                    max(minW, anchor.width + value.translation.width),
                    canvasSize.width - anchor.minX)
                resized.size.height = min(
                    max(minH, anchor.height + value.translation.height),
                    canvasSize.height - anchor.minY)
                draft = resized
                onDragChanged(region(from: resized))
            }
            .onEnded { _ in finishDrag() }
    }

    private func finishDrag() {
        if let draft {
            onDragEnded(region(from: draft))
        }
        anchorRect = nil
        draft = nil
    }

    private func region(from rect: CGRect) -> ScreenRegion {
        ScreenRegion(
            x: rect.minX / canvasSize.width,
            y: rect.minY / canvasSize.height,
            w: rect.width / canvasSize.width,
            h: rect.height / canvasSize.height)
    }
}

/// The gizmo border. A plain dashed rounded-rect stroke starts its
/// pattern at one corner, so only that corner gets a dash that
/// follows the curve. Here the four corner arcs draw SOLID and each
/// edge fits a whole number of dashes with a half-gap at both ends,
/// so every corner looks the same at any size.
private struct GizmoOutline: View {
    private static let lineWidth: CGFloat = 2
    private static let cornerRadius: CGFloat = 6
    private static let dashUnit: CGFloat = 8
    private static let gapUnit: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            let inset = Self.lineWidth / 2
            let r = Self.cornerRadius
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            guard frame.width > 2 * r, frame.height > 2 * r else {
                context.stroke(
                    Path(frame), with: .color(.brand), lineWidth: Self.lineWidth)
                return
            }

            // Solid corners: stroke the rounded rect clipped to four
            // corner squares. No arc-angle math to get wrong.
            let rounded = Path(roundedRect: frame, cornerRadius: r)
            let cornerSide = r + Self.lineWidth
            let corners = [
                CGRect(x: 0, y: 0, width: cornerSide, height: cornerSide),
                CGRect(x: size.width - cornerSide, y: 0, width: cornerSide, height: cornerSide),
                CGRect(
                    x: size.width - cornerSide, y: size.height - cornerSide,
                    width: cornerSide, height: cornerSide),
                CGRect(
                    x: 0, y: size.height - cornerSide, width: cornerSide, height: cornerSide),
            ]
            for corner in corners {
                context.drawLayer { layer in
                    layer.clip(to: Path(corner))
                    layer.stroke(rounded, with: .color(.brand), lineWidth: Self.lineWidth)
                }
            }

            // Edges: scale the dash pattern so a whole number of
            // dash+gap cycles fits, with a half-gap at both ends.
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
                        dashPhase: dash + gap / 2))
            }
            dashedLine(
                from: CGPoint(x: frame.minX + r, y: frame.minY),
                to: CGPoint(x: frame.maxX - r, y: frame.minY))
            dashedLine(
                from: CGPoint(x: frame.maxX, y: frame.minY + r),
                to: CGPoint(x: frame.maxX, y: frame.maxY - r))
            dashedLine(
                from: CGPoint(x: frame.maxX - r, y: frame.maxY),
                to: CGPoint(x: frame.minX + r, y: frame.maxY))
            dashedLine(
                from: CGPoint(x: frame.minX, y: frame.maxY - r),
                to: CGPoint(x: frame.minX, y: frame.minY + r))
        }
        .allowsHitTesting(false)
    }
}

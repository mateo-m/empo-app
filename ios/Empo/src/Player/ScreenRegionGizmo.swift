import GameProbe
import SwiftUI

/// Edit-mode drag/resize gizmo for the screen region. Pure
/// geometry: the parent supplies the rect to show and receives
/// fraction regions through callbacks; ControlsLayout and the
/// bridge applier stay in the parent's hands, so the same gizmo
/// works in the player and on the profile editor's mock canvas.
struct ScreenRegionGizmo: View {
    let canvasSize: CGSize
    /// Where the region may live, in canvas points. The parent
    /// passes the safe-area rect (matching the applier's clamp
    /// policy), so the outline can never disagree with the clamped
    /// region the engine draws.
    let allowedRect: CGRect
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
    /// "Controls over game" toggle. nil hides the chip (the profile
    /// editor's mock canvas has no controls zone to flip).
    var overlayOn: Bool = false
    var onToggleOverlay: (() -> Void)?

    @State private var draft: CGRect?
    @State private var anchorRect: CGRect?
    /// GestureState resets when the system CANCELS a drag (an edge
    /// swipe near the notification shade, an incoming call). The
    /// onChange below then finishes the drag, because a stuck
    /// `screenDragActive` would leave the edit toolbar disabled for
    /// the rest of the session.
    @GestureState private var gestureActive = false

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
                .glassEffect(.regular, in: .capsule)
                .position(x: rect.midX, y: rect.minY + 14)
                .allowsHitTesting(false)

            // Crop-style corner grabber: reads as "drag to resize"
            // where the small circle did not. It sits ON the border
            // corner (like a photo-crop handle on its frame), a
            // touch thicker than the dashes, with a soft shadow so
            // it separates from bright game content. The gesture
            // surface is a larger invisible square so the target
            // stays easy to hit.
            // Brackets on ALL FOUR corners, all draggable — the
            // photo-crop convention users already know. Each one
            // sits fully inside the frame (the viewport edge can
            // never trim it) with an invisible 44 pt touch square.
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
                    .gesture(resizeGesture(for: corner))
                    .accessibilityLabel("Resize game screen")
            }

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
                .position(x: rect.midX, y: rect.minY + 44)
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
                .position(x: rect.midX, y: rect.minY + (showsReset ? 74 : 44))
                .accessibilityLabel(
                    overlayOn
                        ? "Put controls below the game" : "Put controls over the game")
            }
        }
        // Pin the glass pieces to the dark variant like the rest of
        // the player chrome. No implicit animation on rect: in the
        // player the outline follows the engine's ~60 Hz rect
        // stream (the reset tween included), and easing on top of a
        // continuous signal only adds lag. The editor's reset
        // animates through its withAnimation transaction instead.
        .darkGlass()
        .onChange(of: gestureActive) { _, active in
            if !active, anchorRect != nil {
                finishDrag()
            }
        }
    }

    private static let grabberSide: CGFloat = 22

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($gestureActive) { _, state, _ in state = true }
            .onChanged { value in
                if anchorRect == nil {
                    anchorRect = rect
                    onDragBegan()
                }
                guard let anchor = anchorRect else { return }
                var moved = anchor.offsetBy(
                    dx: value.translation.width, dy: value.translation.height)
                moved.origin.x = min(
                    max(allowedRect.minX, moved.origin.x), allowedRect.maxX - moved.width)
                moved.origin.y = min(
                    max(allowedRect.minY, moved.origin.y), allowedRect.maxY - moved.height)
                draft = moved
                onDragChanged(region(from: moved))
            }
            .onEnded { _ in finishDrag() }
    }

    /// The dragged corner moves; the opposite corner anchors.
    private func resizeGesture(for corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($gestureActive) { _, state, _ in state = true }
            .onChanged { value in
                if anchorRect == nil {
                    anchorRect = rect
                    onDragBegan()
                }
                guard let anchor = anchorRect else { return }
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
                onDragChanged(region(from: resized))
            }
            .onEnded { _ in finishDrag() }
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

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

    private func finishDrag() {
        if let draft {
            onDragEnded(region(from: draft))
        }
        anchorRect = nil
        draft = nil
    }

    private func region(from rect: CGRect) -> ScreenRegion {
        // The overlay flag rides along: a drag must not strip the
        // choice the toggle just made.
        ScreenRegion(
            x: rect.minX / canvasSize.width,
            y: rect.minY / canvasSize.height,
            w: rect.width / canvasSize.width,
            h: rect.height / canvasSize.height,
            overlay: overlayOn)
    }
}

/// Crop-style L bracket for the resize corner: a square corner
/// stroke (matching the square outline) that opens toward the
/// region's inside. The round line caps and join keep it soft
/// without lying about the corner shape.
private struct CornerGrabber: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// The gizmo border. SQUARE corners — the game picture has square
/// edges, so a rounded frame would lie about the content. Each edge
/// starts and ends with a HALF dash, so adjacent edges meet in a
/// crisp L-shaped corner dash and all four corners look identical
/// at any size (a plain dashed stroke starts its pattern at one
/// corner only).
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

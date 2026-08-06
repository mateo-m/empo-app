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
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                .background(Color.brand.opacity(0.06))
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
                .position(x: rect.midX, y: rect.maxY - 18)
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

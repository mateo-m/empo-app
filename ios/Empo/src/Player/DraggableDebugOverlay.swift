import SwiftUI

/// Positioned, draggable wrapper around `DebugOverlayView`. Owns its
/// own drag / offset / measured-height state so gesture ticks don't
/// invalidate the parent `PlayerView` body (which would rebuild the
/// D-pad and every action button at ~60 Hz while the overlay is
/// being dragged).
struct DraggableDebugOverlay: View {
    let state: DebugOverlayState
    let visible: Bool
    let isPortrait: Bool
    let gameRect: CGRect
    let safeArea: EdgeInsets
    let geoSize: CGSize
    let useOverlayLayout: Bool

    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var height: CGFloat = AppSize.debugOverlayInitialHeight

    var body: some View {
        if visible {
            innerOverlay
                .transition(.controlAppear(anchor: .topLeading))
        }
    }

    private var innerOverlay: some View {
        DebugOverlayView(state: state)
            .frame(width: AppSize.debugOverlayWidth)
            .contentShape(Rectangle())
            .onPreferenceChange(DebugOverlayHeightKey.self) { newHeight in
                guard newHeight > 0 else { return }
                height = newHeight
                offset = clampDelta(base: .zero, delta: offset)
            }
            .position(anchor)
            .offset(
                x: offset.width + dragOffset.width,
                y: offset.height + dragOffset.height
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = clampDelta(base: offset, delta: value.translation)
                    }
                    .onEnded { value in
                        let clamped = clampDelta(base: offset, delta: value.translation)
                        offset.width += clamped.width
                        offset.height += clamped.height
                        dragOffset = .zero
                    }
            )
            .onChange(of: geoSize) {
                offset = clampDelta(base: .zero, delta: offset)
            }
    }

    private var anchor: CGPoint {
        let halfW = AppSize.debugOverlayWidth / 2
        let halfH = height / 2
        if isPortrait, gameRect.height > 0, !useOverlayLayout {
            return CGPoint(
                x: safeArea.leading + PlayerLayoutTokens.toolbarEdgePad + halfW,
                y: gameRect.origin.y + gameRect.height + PlayerLayoutTokens.toolbarGap + halfH
            )
        } else {
            let leftInset = max(safeArea.leading, PlayerLayoutTokens.minLandscapeInset)
            let topInset = max(safeArea.top, PlayerLayoutTokens.minLandscapeInset)
            return CGPoint(
                x: leftInset + PlayerLayoutTokens.toolbarEdgePad + halfW,
                y: topInset + PlayerLayoutTokens.toolbarEdgePad + halfH
            )
        }
    }

    private func clampDelta(base: CGSize, delta: CGSize) -> CGSize {
        let halfW = AppSize.debugOverlayWidth / 2
        let halfH = height / 2
        let minX = safeArea.leading + halfW
        let maxX = geoSize.width - safeArea.trailing - halfW
        let minY = safeArea.top + halfH
        let maxY = geoSize.height - safeArea.bottom - halfH

        let a = anchor
        let proposedX = a.x + base.width + delta.width
        let proposedY = a.y + base.height + delta.height
        let clampedX = max(minX, min(proposedX, maxX))
        let clampedY = max(minY, min(proposedY, maxY))
        return CGSize(
            width: clampedX - a.x - base.width,
            height: clampedY - a.y - base.height
        )
    }
}

/// Layout constants duplicated into a public enum so the extracted
/// overlay view can reuse them without importing PlayerView's
/// private state. Kept namespaced (`PlayerLayoutTokens`) to avoid
/// clashing with any other design-system enum.
enum PlayerLayoutTokens {
    static let toolbarGap: CGFloat = 8
    static let toolbarEdgePad: CGFloat = 4
    static let minLandscapeInset: CGFloat = 12
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

/// The drag state is in this view, not in `PlayerView`. A change to the
/// `PlayerView` state makes all the controls draw again at each drag event.
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
            // `.position` fills the full proposed space, so measure the
            // region before it. The global frame includes the position
            // and the offset below.
            .chromeHitRegion()
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
                x: safeArea.leading + ControlsZone.toolbarEdgePad + halfW,
                y: gameRect.maxY + ControlsZone.toolbarGap + halfH
            )
        }
        let origin = ControlsZone.topChromeOrigin(safeArea: safeArea)
        return CGPoint(x: origin.x + halfW, y: origin.y + halfH)
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

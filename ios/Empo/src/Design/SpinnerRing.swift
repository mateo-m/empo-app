// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

/// A progress ring: a filled arc when `progress > 0`, a running arc
/// when it is 0. `tint` takes a material, so the ring stays visible on
/// bright and dark artwork.
struct SpinnerRing: View {
    let progress: Double
    var size: CGFloat = 36
    var tint: AnyShapeStyle = AnyShapeStyle(Color.white)
    var trackOpacity: Double = 0.3

    private var isDeterminate: Bool { progress > 0 }
    /// The line is one pixel wide, and sits inside the frame, so it
    /// covers whole pixels of the grid.
    private var ring: PixelRect { PixelRect.pixelCapsule.inset(by: PixelGrid.step / 2) }
    private var style: StrokeStyle {
        StrokeStyle(lineWidth: PixelGrid.step, lineCap: .butt, lineJoin: .miter)
    }

    var body: some View {
        ZStack {
            ring
                .stroke(tint, style: style)
                .opacity(trackOpacity)

            if isDeterminate {
                arc(from: 0, to: progress)
            } else {
                // The arc runs along the ring. A turn of the whole ring
                // would tilt its pixels off the grid.
                TimelineView(.animation) { context in
                    let head = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    arc(from: head, to: head + 0.3)
                }
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.snappy, value: progress)
    }

    private func arc(from start: Double, to end: Double) -> some View {
        ZStack {
            ring.trim(from: start, to: min(end, 1)).stroke(tint, style: style)
            if end > 1 {
                ring.trim(from: 0, to: end - 1).stroke(tint, style: style)
            }
        }
    }
}

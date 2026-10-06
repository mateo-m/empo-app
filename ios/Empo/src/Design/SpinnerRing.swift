import SwiftUI

/// `tint` is `AnyShapeStyle` so a caller can pass a `Material`,
/// which samples the artwork behind the ring for contrast.
struct SpinnerRing: View {
    let progress: Double
    var size: CGFloat = 36
    var lineWidth: CGFloat?
    var tint: AnyShapeStyle = AnyShapeStyle(Color.white)
    var trackOpacity: Double = 0.3

    @State private var start = Date()

    private static let indeterminateArc = 0.3
    private static let turnSeconds = 1.0

    private var isDeterminate: Bool { progress > 0 }
    private var resolvedLineWidth: CGFloat { lineWidth ?? size * 0.097 }
    private var style: StrokeStyle {
        StrokeStyle(lineWidth: resolvedLineWidth, lineCap: .round)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint, lineWidth: resolvedLineWidth)
                .opacity(trackOpacity)
                .frame(width: size, height: size)

            // One arc for both states, so the first real value does
            // not draw a new arc from zero next to the turning one.
            TimelineView(.animation(paused: isDeterminate)) { context in
                let spin = context.date.timeIntervalSince(start) / Self.turnSeconds * 360
                Circle()
                    .trim(from: 0, to: isDeterminate ? progress : Self.indeterminateArc)
                    .stroke(tint, style: style)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(isDeterminate ? Self.topAfter(spin) : spin))
                    .animation(Motion.standard, value: isDeterminate)
            }
        }
        .animation(Motion.snappy, value: progress)
    }

    private static func topAfter(_ spin: Double) -> Double {
        ceil((spin + 90) / 360) * 360 - 90
    }
}

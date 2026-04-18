import SwiftUI

/// Shared circular progress ring used during game imports. Handles both
/// the determinate case (`progress > 0` → radial fill) and the
/// indeterminate case (progress == 0 → spinning 30%-arc).
///
/// Both of those flavors used to live hand-written in `GameCard.swift`
/// (one on the card face, one in the list-row status indicator), with
/// identical trim/stroke/rotation configurations modulo a couple of
/// `frame` and `Color.primary` vs `.white` tweaks. This view unifies
/// them so tweaks land in a single place.
struct SpinnerRing: View {
    let progress: Double
    var size: CGFloat = 36
    var lineWidth: CGFloat? = nil
    var tint: Color = .white
    /// Opacity applied to the background track. The callers used
    /// slightly different track values (0.3 vs 0.2); 0.3 is the more
    /// common case, callers that need 0.2 override it here.
    var trackOpacity: Double = 0.3

    @State private var spinning = false

    private var isDeterminate: Bool { progress > 0 }
    private var resolvedLineWidth: CGFloat { lineWidth ?? size * 0.097 }
    private var style: StrokeStyle {
        StrokeStyle(lineWidth: resolvedLineWidth, lineCap: .round)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(trackOpacity), lineWidth: resolvedLineWidth)
                .frame(width: size, height: size)

            if isDeterminate {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: style)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(tint, style: style)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear { spinning = true }
                    .animation(
                        .linear(duration: 1).repeatForever(autoreverses: false),
                        value: spinning
                    )
            }
        }
        .animation(Motion.snappy, value: progress)
    }
}

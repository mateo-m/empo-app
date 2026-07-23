import SwiftUI

/// Shared circular progress ring for game imports. Handles both
/// the determinate case (`progress > 0` -> radial fill) and the
/// indeterminate case (progress == 0 -> spinning 30%-arc).
///
/// Both variants used to live hand-written in `GameCard.swift`
/// (one on the card face, one in the list-row status indicator).
/// The two copies had the same trim/stroke/rotation setup apart
/// from a couple of `frame` and `Color.primary` vs `.white` tweaks.
/// This view unifies them so a tweak lands in a single place.
///
/// `tint` is `AnyShapeStyle` so callers can pass a `Color` for fixed
/// branding (e.g. the import button uses `.white` against its tinted
/// background) or a `Material` (e.g. `.regularMaterial`) for
/// adaptive contrast against arbitrary artwork. Materials sample the
/// backdrop and produce the right luminance automatically. A progress
/// card on a bright Pokemon title screen and one on a dark cinematic
/// both get a visible ring, and the indicator does not need to know
/// what is behind it.
struct SpinnerRing: View {
    let progress: Double
    var size: CGFloat = 36
    var lineWidth: CGFloat?
    var tint: AnyShapeStyle = AnyShapeStyle(Color.white)
    /// Opacity for the background track. The callers used slightly
    /// different track values (0.3 vs 0.2). 0.3 is the more common
    /// case. Callers that need 0.2 override it here.
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
                .stroke(tint, lineWidth: resolvedLineWidth)
                .opacity(trackOpacity)
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
                    .animation(Motion.spinner, value: spinning)
            }
        }
        .animation(Motion.snappy, value: progress)
    }
}

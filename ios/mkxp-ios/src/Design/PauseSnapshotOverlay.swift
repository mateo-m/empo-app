import SwiftUI

/// Displays the pause-snapshot bitmap at the engine's game-rect position
/// so it aligns exactly with where SDL would have been drawing. Used by
/// both `GameLoadingView` (on resume, the bitmap holds until the first
/// live frame is rendered) and `PlayerView` (fades out once the first
/// post-resume frame swaps in).
///
/// Pure presentation: takes the image + rect + opacity as inputs, has
/// no state or controller dependencies.
struct PauseSnapshotOverlay: View {
    let snapshot: UIImage
    let rect: CGRect
    /// Rendered with 1.0 opacity by default. Callers that animate a
    /// cross-fade pass a bound value here.
    var opacity: Double = 1

    var body: some View {
        Image(uiImage: snapshot)
            .resizable()
            .interpolation(.high)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

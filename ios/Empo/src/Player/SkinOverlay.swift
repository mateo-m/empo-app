import SwiftUI

/// Profile skin art over the game, with a hole where the game draws.
///
/// The SDL game view sits UNDER the SwiftUI chrome, so art cannot go
/// behind the game. Instead the art covers the whole container and an
/// even-odd mask cuts out `gameRect`, so the game shows through the
/// painted screen window and the hole follows the screen-region
/// gizmo live. Never hit-testable: touches reach the game and the
/// controls above it.
struct SkinOverlay: View {
    let image: UIImage
    /// In the container's coordinates. The player passes window
    /// points and places this view with `.ignoresSafeArea()` so the
    /// spaces match. The editor passes canvas points and keeps the
    /// canvas frame.
    let gameRect: CGRect

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .mask {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geo.size))
                        if !gameRect.isEmpty {
                            path.addRect(gameRect)
                        }
                    }
                    .fill(style: FillStyle(eoFill: true))
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// True while profile skin art replaces the controls' drawing.
    /// Controls then paint nothing, while their touch capture stays
    /// live. Never apply it to a `ControlTouchCapture`: UIKit skips
    /// hit-testing views below 0.01 alpha.
    @Entry var controlsDrawingHidden = false
}

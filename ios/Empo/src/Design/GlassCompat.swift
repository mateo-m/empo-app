import SwiftUI

/// Material-based approximation of Liquid Glass for iOS versions before 26,
/// where `View.glassEffect(_:in:)` doesn't exist. Mirrors the rough visual
/// weight of `.regular` glass (translucent fill + faint edge) without
/// depending on any iOS-26-only SwiftUI symbol.
extension View {
    @ViewBuilder
    func legacyGlassFallback<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        self
            .background(
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill((tint ?? .white).opacity(tint == nil ? 0 : 0.16)))
            )
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}

import SwiftUI

/// Window-coordinate chrome rects that `PlayerView` publishes so
/// `AppWindow.hitTest` can route touches without a check on view
/// identity (SwiftUI's hosting view is hit-testable everywhere).
@MainActor
enum ChromeHitRegions {
    private static var regions: [String: CGRect] = [:]
    private static let slop: CGFloat = 6

    static func update(_ id: String, rect: CGRect) {
        regions[id] = rect
    }

    static func remove(_ id: String) {
        regions.removeValue(forKey: id)
    }

    static func removeAll() {
        regions.removeAll()
    }

    static func contains(_ point: CGPoint) -> Bool {
        for rect in regions.values {
            let inflated = rect.insetBy(dx: -slop, dy: -slop)
            if inflated.contains(point) {
                return true
            }
        }
        return false
    }
}

private struct ChromeHitRegionModifier: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                ChromeHitRegions.update(id, rect: frame)
            }
            .onDisappear {
                ChromeHitRegions.remove(id)
            }
    }
}

extension View {
    /// Publish this view's global frame for `AppWindow` hit routing.
    func chromeHitRegion(_ id: String) -> some View {
        modifier(ChromeHitRegionModifier(id: id))
    }
}

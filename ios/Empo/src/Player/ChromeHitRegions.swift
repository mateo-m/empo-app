// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

/// The SwiftUI hosting view accepts a hit at every point. `AppWindow.hitTest`
/// uses these window rects to find the touches that go to the chrome.
@MainActor
enum ChromeHitRegions {
    fileprivate static var regions: [UUID: CGRect] = [:]
    private static let slop: CGFloat = 6

    static func removeAll() {
        regions.removeAll()
    }

    static func contains(_ point: CGPoint) -> Bool {
        regions.values.contains { $0.insetBy(dx: -slop, dy: -slop).contains(point) }
    }
}

private struct ChromeHitRegionModifier: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                ChromeHitRegions.regions[id] = frame
            }
            .onDisappear {
                ChromeHitRegions.regions[id] = nil
            }
    }
}

extension View {
    /// The profile editor shows the controls outside the player. There,
    /// `enabled` is false, so the regions do not change the hit routing.
    @ViewBuilder
    func chromeHitRegion(enabled: Bool = true) -> some View {
        if enabled {
            modifier(ChromeHitRegionModifier())
        } else {
            self
        }
    }
}

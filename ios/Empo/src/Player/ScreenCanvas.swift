// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// A surface that shows the game screen: the app window, or the mock
/// phone of the profile editor. A `ScreenRegion` holds fractions of
/// `size`.
struct ScreenCanvas {
    var size: CGSize
    var safeArea: EdgeInsets

    var isPortrait: Bool { ControlsOrientation.from(geoSize: size) == .portrait }

    /// The part of the canvas that the game screen can use. Sideways,
    /// the top and bottom insets do not apply: the engine also ignores
    /// them, because the home indicator hides by itself.
    var safeRect: CGRect {
        let top = isPortrait ? safeArea.top : 0
        let bottom = isPortrait ? size.height - safeArea.bottom : size.height
        return CGRect(
            x: safeArea.leading, y: top,
            width: size.width - safeArea.leading - safeArea.trailing,
            height: bottom - top)
    }

    func rect(for region: ScreenRegion) -> CGRect {
        CGRect(
            x: region.x * size.width, y: region.y * size.height,
            width: region.w * size.width, height: region.h * size.height)
    }

    func region(for rect: CGRect, overlay: Bool = false) -> ScreenRegion {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        return ScreenRegion(
            x: rect.minX / width, y: rect.minY / height,
            w: rect.width / width, h: rect.height / height,
            overlay: overlay)
    }

    /// A preset has no rect until the aspect of the game is known.
    func region(for placement: ScreenPlacement, aspect: CGFloat?) -> ScreenRegion? {
        switch placement {
        case .region(let region):
            return region
        case .preset(let preset):
            guard let aspect else { return nil }
            return ScreenPresetPlacement.region(
                preset: preset,
                canvasWidth: Double(size.width),
                canvasHeight: Double(size.height),
                safeTop: Double(safeArea.top),
                safeBottom: Double(safeArea.bottom),
                safeLeading: Double(safeArea.leading),
                safeTrailing: Double(safeArea.trailing),
                isPortrait: isPortrait,
                aspect: Double(aspect))
        }
    }

    /// Moves the region into `safeRect` first, and makes it smaller
    /// only when it cannot fit. The minimum size stays.
    func clampedToSafeArea(_ region: ScreenRegion) -> ScreenRegion {
        guard size.width > 0, size.height > 0 else { return region }
        let safe = self.region(for: safeRect)
        let minimum = ScreenRegionFile.minFraction
        let w = max(min(region.w, safe.w), min(minimum, safe.w))
        let h = max(min(region.h, safe.h), min(minimum, safe.h))
        return ScreenRegion(
            x: min(max(region.x, safe.x), safe.x + safe.w - w),
            y: min(max(region.y, safe.y), safe.y + safe.h - h),
            w: w, h: h, overlay: region.overlay)
    }
}

extension CGRect {
    /// Makes the rect smaller until it fits in `bounds`, then moves it
    /// inside.
    func kept(inside bounds: CGRect) -> CGRect {
        let width = min(self.width, bounds.width)
        let height = min(self.height, bounds.height)
        return CGRect(
            x: min(max(bounds.minX, minX), bounds.maxX - width),
            y: min(max(bounds.minY, minY), bounds.maxY - height),
            width: width, height: height)
    }
}

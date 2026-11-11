// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// A profile stores the preset, not this rect. The rect uses device
/// numbers, so it is made again on each device at apply time.
public enum ScreenPresetPlacement {
    /// The result is in fractions of the canvas, with a top-left origin.
    public static func region(
        preset: ScreenPreset,
        canvasWidth: Double,
        canvasHeight: Double,
        safeTop: Double,
        safeBottom: Double,
        safeLeading: Double,
        safeTrailing: Double,
        isPortrait: Bool,
        aspect: Double
    ) -> ScreenRegion? {
        guard canvasWidth > 0, canvasHeight > 0, aspect > 0 else { return nil }
        let availW = canvasWidth - safeLeading - safeTrailing
        let availH = isPortrait ? canvasHeight - safeTop - safeBottom : canvasHeight
        guard availW > 1, availH > 1 else { return nil }

        let (width, height) = GameAspect.fit(width: availW, height: availH, aspect: aspect)
        let x = safeLeading + (availW - width) / 2

        let y: Double
        if isPortrait {
            let topY = safeTop
            let centerY = safeTop + (availH - height) / 2
            switch preset {
            case .top: y = topY
            case .center: y = centerY
            case .topCenter: y = (topY + centerY) / 2
            }
        } else {
            // Landscape auto centers the full height. The presets
            // do not differ there.
            y = (availH - height) / 2
        }
        return ScreenRegion(
            x: x / canvasWidth, y: y / canvasHeight,
            w: width / canvasWidth, h: height / canvasHeight)
    }
}

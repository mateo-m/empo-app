import Foundation

/// Computes a preset's rect for the CURRENT device: the aspect-fit
/// rect inside the safe container, aligned per the preset — the
/// same math as the engine's automatic placement. A preset never
/// bakes device numbers into a profile; this runs at apply time,
/// so one profile places the game right on an iPhone and an iPad
/// alike.
public enum ScreenPresetPlacement {
    /// nil when the inputs cannot produce a rect (degenerate canvas
    /// or aspect). Fractions of the canvas, top-left origin.
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

        var width = availW
        var height = width / aspect
        if height > availH {
            height = availH
            width = height * aspect
        }
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
            // Landscape auto centers the full height; the presets
            // do not differ there.
            y = (availH - height) / 2
        }
        return ScreenRegion(
            x: x / canvasWidth, y: y / canvasHeight,
            w: width / canvasWidth, h: height / canvasHeight)
    }
}

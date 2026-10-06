import Foundation
import GameProbe

/// Render-resolution multiplier applied via mkxp-z's `enableHires`
/// + `framebufferScalingFactor`. RGSS games render to a buffer with
/// a fixed aspect ratio (544x416 for RGSS3, 640x480 for RGSS1) that
/// can't change without breaking the game's UI layout. What we can
/// do is render that buffer at a higher pixel count before
/// downscaling to the screen, which sharpens lines and text.
enum RenderScale: String, Codable, CaseIterable, Hashable {
    case x1
    case x2
    case x4

    var label: String {
        switch self {
        case .x1: "Default"
        case .x2: "High (2x)"
        case .x4: "Very high (4x)"
        }
    }

    var description: String {
        switch self {
        case .x1: "Native game resolution."
        case .x2: "Draw the game at 2x its normal size. Sharper on high-resolution screens."
        case .x4: "Draw the game at 4x its normal size. Sharpest, but harder on the battery."
        }
    }

    /// Multiplier written to mkxp.json as `framebufferScalingFactor`.
    /// `x1` returns 1.0 but the host strips both `enableHires` and
    /// `framebufferScalingFactor` for that case so the engine falls
    /// back to its native-resolution path.
    var framebufferScalingFactor: Double {
        switch self {
        case .x1: 1.0
        case .x2: 2.0
        case .x4: 4.0
        }
    }

    var enableHires: Bool {
        self != .x1
    }
}

/// The mkxp-z settings of one game, kept in the sparse
/// `EmpoState/mkxp.json` overlay. A nil value follows the game's own
/// `Game/mkxp.json`.
struct MkxpEngineSettings: Equatable {
    var renderScale: RenderScale?
    var frameSkip: Bool?
    /// No settings row shows this one. iOS composites every frame on
    /// the display refresh, so the engine cannot turn VSync off and
    /// a toggle would promise something it cannot do. The field
    /// stays because overlays written by older builds and imported
    /// JGP profiles still carry the value, and "Reset to defaults"
    /// must be able to clear it.
    var vsync: Bool?
    var pathCache: Bool?
    var fontScale: Double?
    var solidFonts: Bool?

    static let engineFrameSkip = false
    static let enginePathCache = true
    static let engineFontScale = 1.0
    static let engineSolidFonts = false
    static let engineRenderScale = RenderScale.x1

    private var overlayProvenance: [MkxpEngineField: MkxpValueProvenance] = [:]

    init(values: MkxpEngineValues) {
        self.renderScale = Self.renderScale(from: values)
        self.frameSkip = values.frameSkip
        self.vsync = values.vsync
        self.pathCache = values.pathCache
        self.fontScale = values.fontScale
        self.solidFonts = values.solidFonts
    }

    static func load(from stateDirectory: URL) -> MkxpEngineSettings {
        var settings = MkxpEngineSettings(values: ManagedMkxpConfig.readOverlay(from: stateDirectory))
        for field in MkxpEngineField.allCases {
            settings.overlayProvenance[field] = ManagedMkxpConfig.provenance(
                for: field, stateDirectory: stateDirectory)
        }
        return settings
    }

    /// The values of the game's own `Game/mkxp.json`.
    static func gameDefaults(in gameDirectory: URL) -> MkxpEngineSettings {
        let defaults = ManagedMkxpConfig.readGameDefaults(from: gameDirectory)
        return MkxpEngineSettings(
            values: MkxpEngineValues(
                renderScaleEnableHires: defaults.renderScaleEnableHires,
                renderScaleFramebufferFactor: defaults.renderScaleFramebufferFactor,
                frameSkip: defaults.frameSkip,
                vsync: defaults.vsync,
                pathCache: defaults.pathCache,
                fontScale: defaults.fontScale,
                solidFonts: defaults.solidFonts
            ))
    }

    func isChanged(_ field: MkxpEngineField) -> Bool {
        if overlayProvenance[field] == .yours { return true }
        switch field {
        case .renderScale: return renderScale != nil
        case .frameSkip: return frameSkip != nil
        case .vsync: return vsync != nil
        case .pathCache: return pathCache != nil
        case .fontScale: return fontScale != nil
        case .solidFonts: return solidFonts != nil
        }
    }

    var hasOverrides: Bool {
        MkxpEngineField.allCases.contains(where: isChanged)
    }

    var mkxpValues: MkxpEngineValues {
        var values = MkxpEngineValues(
            frameSkip: frameSkip,
            vsync: vsync,
            pathCache: pathCache,
            fontScale: fontScale,
            solidFonts: solidFonts
        )
        if let scale = renderScale {
            values.renderScaleEnableHires = scale.enableHires
            values.renderScaleFramebufferFactor = scale.framebufferScalingFactor
        }
        return values
    }

    func save(to stateDirectory: URL) {
        ManagedMkxpConfig.writeOverlay(overrides: mkxpValues, stateDirectory: stateDirectory)
    }

    func restartRequiredFieldsChanged(from other: MkxpEngineSettings) -> [String] {
        var changed: [String] = []
        if renderScale != other.renderScale { changed.append("Render scale") }
        if frameSkip != other.frameSkip { changed.append("Frame skip") }
        if pathCache != other.pathCache { changed.append("Path cache") }
        if fontScale != other.fontScale { changed.append("Font scale") }
        if solidFonts != other.solidFonts { changed.append("Solid fonts") }
        return changed
    }

    private static func renderScale(from values: MkxpEngineValues) -> RenderScale? {
        guard let enableHires = values.renderScaleEnableHires else { return nil }
        guard enableHires else { return .x1 }
        let factor = values.renderScaleFramebufferFactor ?? 1.0
        switch factor {
        case ..<1.5: return .x1
        case ..<3.0: return .x2
        default: return .x4
        }
    }
}

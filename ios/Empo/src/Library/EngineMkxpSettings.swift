import Foundation
import GameProbe

/// Live engine settings backed by `EmpoState/mkxp.json`. The eight
/// projector keys are no longer stored in `game_settings.json`.
struct EngineMkxpSettings: Equatable {
    var smoothScaling: Bool?
    var fixedAspectRatio: Bool?
    var renderScale: RenderScale?
    var frameSkip: Bool?
    var vsync: Bool?
    var pathCache: Bool?
    var fontScale: Double?
    var solidFonts: Bool?

    /// True when the developer's `Game/mkxp.json` exists but cannot be
    /// parsed. Engine rows are read-only in this case.
    let isReadOnly: Bool

    init(
        smoothScaling: Bool? = nil,
        fixedAspectRatio: Bool? = nil,
        renderScale: RenderScale? = nil,
        frameSkip: Bool? = nil,
        vsync: Bool? = nil,
        pathCache: Bool? = nil,
        fontScale: Double? = nil,
        solidFonts: Bool? = nil,
        isReadOnly: Bool = false
    ) {
        self.smoothScaling = smoothScaling
        self.fixedAspectRatio = fixedAspectRatio
        self.renderScale = renderScale
        self.frameSkip = frameSkip
        self.vsync = vsync
        self.pathCache = pathCache
        self.fontScale = fontScale
        self.solidFonts = solidFonts
        self.isReadOnly = isReadOnly
    }

    static func load(from stateDirectory: URL, gameDirectory: URL) -> EngineMkxpSettings {
        let readOnly = ManagedMkxpConfig.isDevConfigUnparseable(gameDirectory: gameDirectory)
        let values = ManagedMkxpConfig.readManaged(from: stateDirectory)
        return EngineMkxpSettings(values: values, isReadOnly: readOnly)
    }

    init(values: MkxpEngineValues, isReadOnly: Bool = false) {
        self.smoothScaling = values.smoothScaling
        self.fixedAspectRatio = values.fixedAspectRatio
        self.renderScale = Self.renderScale(from: values)
        self.frameSkip = values.frameSkip
        self.vsync = values.vsync
        self.pathCache = values.pathCache
        self.fontScale = values.fontScale
        self.solidFonts = values.solidFonts
        self.isReadOnly = isReadOnly
    }

    var mkxpValues: MkxpEngineValues {
        var values = MkxpEngineValues(
            smoothScaling: smoothScaling,
            fixedAspectRatio: fixedAspectRatio,
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

    func hasOverrides(devDefaults: GameConfigDefaults) -> Bool {
        effectiveBool(smoothScaling, devDefaults.smoothScaling, GameConfigDefaults.engineSmoothScaling)
            != (devDefaults.smoothScaling ?? GameConfigDefaults.engineSmoothScaling)
            || effectiveBool(
                fixedAspectRatio, devDefaults.fixedAspectRatio, GameConfigDefaults.engineFixedAspectRatio
            )
                != (devDefaults.fixedAspectRatio ?? GameConfigDefaults.engineFixedAspectRatio)
            || effectiveRenderScale(devDefaults)
                != (devDefaults.renderScale ?? GameConfigDefaults.engineRenderScale)
            || effectiveBool(frameSkip, devDefaults.frameSkip, GameConfigDefaults.engineFrameSkip)
                != (devDefaults.frameSkip ?? GameConfigDefaults.engineFrameSkip)
            || effectiveBool(vsync, devDefaults.vsync, GameConfigDefaults.engineVsync)
                != (devDefaults.vsync ?? GameConfigDefaults.engineVsync)
            || effectiveBool(pathCache, devDefaults.pathCache, GameConfigDefaults.enginePathCache)
                != (devDefaults.pathCache ?? GameConfigDefaults.enginePathCache)
            || effectiveDouble(fontScale, devDefaults.fontScale, GameConfigDefaults.engineFontScale)
                != (devDefaults.fontScale ?? GameConfigDefaults.engineFontScale)
            || effectiveBool(solidFonts, devDefaults.solidFonts, GameConfigDefaults.engineSolidFonts)
                != (devDefaults.solidFonts ?? GameConfigDefaults.engineSolidFonts)
    }

    func save(to stateDirectory: URL, gameDirectory: URL) {
        guard !isReadOnly else { return }
        ManagedMkxpConfig.updateManaged(
            overrides: mkxpValues,
            stateDirectory: stateDirectory,
            gameDirectory: gameDirectory
        )
    }

    mutating func resetToDefaults(gameDirectory: URL, stateDirectory: URL) {
        guard !isReadOnly else { return }
        let devDefaults = ManagedMkxpConfig.readGameDefaults(from: gameDirectory)
        ManagedMkxpConfig.resetAllEngineFields(
            stateDirectory: stateDirectory,
            gameDirectory: gameDirectory,
            devDefaults: devDefaults
        )
        self = EngineMkxpSettings.load(from: stateDirectory, gameDirectory: gameDirectory)
    }

    func restartRequiredFieldsChanged(from other: EngineMkxpSettings) -> [String] {
        var changed: [String] = []
        if smoothScaling != other.smoothScaling { changed.append("Smooth scaling") }
        if fixedAspectRatio != other.fixedAspectRatio { changed.append("Fixed aspect ratio") }
        if renderScale != other.renderScale { changed.append("Render scale") }
        if frameSkip != other.frameSkip { changed.append("Frame skip") }
        if vsync != other.vsync { changed.append("VSync") }
        if pathCache != other.pathCache { changed.append("Path cache") }
        if fontScale != other.fontScale { changed.append("Font scale") }
        if solidFonts != other.solidFonts { changed.append("Solid fonts") }
        return changed
    }

    private func effectiveBool(_ value: Bool?, _ dev: Bool?, _ engine: Bool) -> Bool {
        value ?? dev ?? engine
    }

    private func effectiveDouble(_ value: Double?, _ dev: Double?, _ engine: Double) -> Double {
        value ?? dev ?? engine
    }

    private func effectiveRenderScale(_ devDefaults: GameConfigDefaults) -> RenderScale {
        renderScale ?? devDefaults.renderScale ?? GameConfigDefaults.engineRenderScale
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

extension GameConfigDefaults {
    init(mkxpDefaults: MkxpGameDefaults) {
        let renderValues = MkxpEngineValues(
            renderScaleEnableHires: mkxpDefaults.renderScaleEnableHires,
            renderScaleFramebufferFactor: mkxpDefaults.renderScaleFramebufferFactor
        )
        self.init(
            smoothScaling: mkxpDefaults.smoothScaling,
            fixedAspectRatio: mkxpDefaults.fixedAspectRatio,
            renderScale: EngineMkxpSettings(values: renderValues).renderScale,
            frameSkip: mkxpDefaults.frameSkip,
            vsync: mkxpDefaults.vsync,
            pathCache: mkxpDefaults.pathCache,
            fontScale: mkxpDefaults.fontScale,
            solidFonts: mkxpDefaults.solidFonts
        )
    }
}

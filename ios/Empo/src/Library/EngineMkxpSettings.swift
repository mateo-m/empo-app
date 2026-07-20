import Foundation
import GameProbe

/// Live engine settings backed by the sparse `EmpoState/mkxp.json`
/// overlay. Effective values merge the overlay with `Game/mkxp.json`.
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
    /// parsed by the host. Rows stay editable; dev-default annotations
    /// degrade to unknown.
    let gameDefaultsUnknown: Bool

    private let overlayProvenance: [MkxpEngineField: MkxpValueProvenance]

    init(
        smoothScaling: Bool? = nil,
        fixedAspectRatio: Bool? = nil,
        renderScale: RenderScale? = nil,
        frameSkip: Bool? = nil,
        vsync: Bool? = nil,
        pathCache: Bool? = nil,
        fontScale: Double? = nil,
        solidFonts: Bool? = nil,
        gameDefaultsUnknown: Bool = false,
        overlayProvenance: [MkxpEngineField: MkxpValueProvenance] = [:]
    ) {
        self.smoothScaling = smoothScaling
        self.fixedAspectRatio = fixedAspectRatio
        self.renderScale = renderScale
        self.frameSkip = frameSkip
        self.vsync = vsync
        self.pathCache = pathCache
        self.fontScale = fontScale
        self.solidFonts = solidFonts
        self.gameDefaultsUnknown = gameDefaultsUnknown
        self.overlayProvenance = overlayProvenance
    }

    static func load(from stateDirectory: URL, gameDirectory: URL) -> EngineMkxpSettings {
        let defaultsUnknown = ManagedMkxpConfig.isDevConfigUnparseable(gameDirectory: gameDirectory)
        let values = ManagedMkxpConfig.readOverlay(from: stateDirectory)
        var provenance: [MkxpEngineField: MkxpValueProvenance] = [:]
        for field in MkxpEngineField.allCases {
            provenance[field] = ManagedMkxpConfig.provenance(for: field, stateDirectory: stateDirectory)
        }
        return EngineMkxpSettings(
            values: values,
            gameDefaultsUnknown: defaultsUnknown,
            overlayProvenance: provenance
        )
    }

    init(
        values: MkxpEngineValues,
        gameDefaultsUnknown: Bool = false,
        overlayProvenance: [MkxpEngineField: MkxpValueProvenance] = [:]
    ) {
        self.smoothScaling = values.smoothScaling
        self.fixedAspectRatio = values.fixedAspectRatio
        self.renderScale = Self.renderScale(from: values)
        self.frameSkip = values.frameSkip
        self.vsync = values.vsync
        self.pathCache = values.pathCache
        self.fontScale = values.fontScale
        self.solidFonts = values.solidFonts
        self.gameDefaultsUnknown = gameDefaultsUnknown
        self.overlayProvenance = overlayProvenance
    }

    func provenance(for field: MkxpEngineField) -> MkxpValueProvenance {
        overlayProvenance[field] ?? .game
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
        MkxpEngineField.allCases.contains { provenance(for: $0) == .yours }
    }

    func save(to stateDirectory: URL, gameDirectory: URL) {
        ManagedMkxpConfig.updateManaged(
            overrides: mkxpValues,
            stateDirectory: stateDirectory,
            gameDirectory: gameDirectory
        )
    }

    mutating func resetField(
        _ field: MkxpEngineField,
        gameDirectory: URL,
        stateDirectory: URL
    ) {
        ManagedMkxpConfig.resetField(
            field,
            stateDirectory: stateDirectory,
            gameDirectory: gameDirectory
        )
        self = EngineMkxpSettings.load(from: stateDirectory, gameDirectory: gameDirectory)
    }

    mutating func resetToDefaults(gameDirectory: URL, stateDirectory: URL) {
        ManagedMkxpConfig.resetAllEngineFields(
            stateDirectory: stateDirectory,
            gameDirectory: gameDirectory
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

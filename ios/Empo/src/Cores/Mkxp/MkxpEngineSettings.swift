// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

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

    var label: LocalizedStringResource {
        switch self {
        case .x1:
            LocalizedStringResource("Default", comment: "Render scale option: the game's own resolution.")
        case .x2: "High (2x)"
        case .x4: "Very high (4x)"
        }
    }

    var description: LocalizedStringResource {
        switch self {
        case .x1: "Draw the game at its own resolution."
        case .x2:
            "Draw the game at 2x its normal size. Sharper on high-resolution screens. The game still fits the screen the same way."
        case .x4:
            "Draw the game at 4x its normal size. Sharpest, but uses more battery. The game still fits the screen the same way."
        }
    }

    var mkxp: MkxpRenderScale {
        switch self {
        case .x1: .native
        case .x2: .hires(factor: 2.0)
        case .x4: .hires(factor: 4.0)
        }
    }

    init(_ scale: MkxpRenderScale) {
        switch scale {
        case .native: self = .x1
        case .hires(let factor) where factor < 1.5: self = .x1
        case .hires(let factor) where factor < 3.0: self = .x2
        case .hires: self = .x4
        }
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
        self.renderScale = values.renderScale.map(RenderScale.init)
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
                renderScale: defaults.renderScale,
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
        MkxpEngineValues(
            renderScale: renderScale?.mkxp,
            frameSkip: frameSkip,
            vsync: vsync,
            pathCache: pathCache,
            fontScale: fontScale,
            solidFonts: solidFonts
        )
    }

    func save(to stateDirectory: URL) {
        ManagedMkxpConfig.writeOverlay(overrides: mkxpValues, stateDirectory: stateDirectory)
    }

    func restartRequiredFieldsChanged(from other: MkxpEngineSettings) -> [String] {
        var changed: [String] = []
        if renderScale != other.renderScale { changed.append(String(localized: "Render scale")) }
        if frameSkip != other.frameSkip { changed.append(String(localized: "Frame skip")) }
        if pathCache != other.pathCache { changed.append(String(localized: "Path cache")) }
        if fontScale != other.fontScale { changed.append(String(localized: "Font scale")) }
        if solidFonts != other.solidFonts { changed.append(String(localized: "Solid fonts")) }
        return changed
    }
}

import Foundation

/// The eight engine settings Empo surfaces in Game Settings and stores
/// in `EmpoState/mkxp.json`. Keys match mkxp-z's config surface.
public struct MkxpEngineValues: Equatable, Sendable {
    public var smoothScaling: Bool?
    public var fixedAspectRatio: Bool?
    /// `nil` = native resolution (`enableHires` false, factor stripped).
    public var renderScaleEnableHires: Bool?
    public var renderScaleFramebufferFactor: Double?
    public var frameSkip: Bool?
    public var vsync: Bool?
    public var pathCache: Bool?
    public var fontScale: Double?
    public var solidFonts: Bool?

    public init(
        smoothScaling: Bool? = nil,
        fixedAspectRatio: Bool? = nil,
        renderScaleEnableHires: Bool? = nil,
        renderScaleFramebufferFactor: Double? = nil,
        frameSkip: Bool? = nil,
        vsync: Bool? = nil,
        pathCache: Bool? = nil,
        fontScale: Double? = nil,
        solidFonts: Bool? = nil
    ) {
        self.smoothScaling = smoothScaling
        self.fixedAspectRatio = fixedAspectRatio
        self.renderScaleEnableHires = renderScaleEnableHires
        self.renderScaleFramebufferFactor = renderScaleFramebufferFactor
        self.frameSkip = frameSkip
        self.vsync = vsync
        self.pathCache = pathCache
        self.fontScale = fontScale
        self.solidFonts = solidFonts
    }
}

/// Developer defaults read from `Game/mkxp.json` for UI annotations.
public struct MkxpGameDefaults: Equatable, Sendable {
    public var smoothScaling: Bool?
    public var fixedAspectRatio: Bool?
    public var renderScaleEnableHires: Bool?
    public var renderScaleFramebufferFactor: Double?
    public var frameSkip: Bool?
    public var vsync: Bool?
    public var pathCache: Bool?
    public var fontScale: Double?
    public var solidFonts: Bool?

    public init(
        smoothScaling: Bool? = nil,
        fixedAspectRatio: Bool? = nil,
        renderScaleEnableHires: Bool? = nil,
        renderScaleFramebufferFactor: Double? = nil,
        frameSkip: Bool? = nil,
        vsync: Bool? = nil,
        pathCache: Bool? = nil,
        fontScale: Double? = nil,
        solidFonts: Bool? = nil
    ) {
        self.smoothScaling = smoothScaling
        self.fixedAspectRatio = fixedAspectRatio
        self.renderScaleEnableHires = renderScaleEnableHires
        self.renderScaleFramebufferFactor = renderScaleFramebufferFactor
        self.frameSkip = frameSkip
        self.vsync = vsync
        self.pathCache = pathCache
        self.fontScale = fontScale
        self.solidFonts = solidFonts
    }

    public func defines(_ field: MkxpEngineField) -> Bool {
        switch field {
        case .smoothScaling: smoothScaling != nil
        case .fixedAspectRatio: fixedAspectRatio != nil
        case .renderScale: renderScaleEnableHires != nil
        case .frameSkip: frameSkip != nil
        case .vsync: vsync != nil
        case .pathCache: pathCache != nil
        case .fontScale: fontScale != nil
        case .solidFonts: solidFonts != nil
        }
    }
}

public enum MkxpEngineField: String, CaseIterable, Sendable {
    case smoothScaling
    case fixedAspectRatio
    case renderScale
    case frameSkip
    case vsync
    case pathCache
    case fontScale
    case solidFonts
}

/// Whether an engine setting row's effective value comes from the game
/// base (`Game/mkxp.json` or engine default) or the user's overlay.
public enum MkxpValueProvenance: Equatable, Sendable {
    case game
    case yours
}

/// Keys that used to live in `game_settings.json` before the mkxp accessor
/// migration. Used for one-time idempotent migration.
public enum ManagedMkxpConfig {
    public static let legacyGameSettingsKeys: [String] = [
        "smoothScaling",
        "fixedAspectRatio",
        "renderScale",
        "frameSkip",
        "vsync",
        "pathCache",
        "fontScale",
        "solidFonts",
    ]

    private static let configFilename = "mkxp.json"
    private static let settingsFilename = "game_settings.json"
    private static let legacyEngineDirectoryName = ".engine"

    // MARK: - Paths

    public static func overlayConfigURL(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent(configFilename)
    }

    /// Sparse overlay at `EmpoState/mkxp.json`.
    public static func managedConfigURL(in stateDirectory: URL) -> URL {
        overlayConfigURL(in: stateDirectory)
    }

    public static func devConfigURL(in gameDirectory: URL) -> URL {
        gameDirectory.appendingPathComponent(configFilename)
    }

    /// One-time cleanup for the retired composed-config directory.
    public static func removeLegacyEngineConfigDirectory(in stateDirectory: URL) {
        let engineDir = stateDirectory.appendingPathComponent(
            legacyEngineDirectoryName,
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: engineDir)
    }

    // MARK: - Read

    /// True when `Game/mkxp.json` exists but cannot be parsed. Used only
    /// for UI annotations; the engine still reads the base file itself.
    public static func isDevConfigUnparseable(gameDirectory: URL) -> Bool {
        let sourceURL = devConfigURL(in: gameDirectory)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return false }
        guard let raw = try? String(contentsOf: sourceURL, encoding: .utf8) else { return true }
        return parseJSONWithComments(raw) == nil
    }

    /// Values stored in the sparse overlay only (missing keys are nil).
    public static func readOverlay(from stateDirectory: URL) -> MkxpEngineValues {
        guard let overlay = loadOverlayDict(from: stateDirectory) else {
            return MkxpEngineValues()
        }
        return values(from: overlay)
    }

    /// Effective values after merging `Game/mkxp.json` with the overlay.
    public static func readEffective(
        stateDirectory: URL,
        gameDirectory: URL
    ) -> MkxpEngineValues {
        let base = loadBaseDict(from: gameDirectory) ?? [:]
        let overlay = loadOverlayDict(from: stateDirectory) ?? [:]
        var merged = base
        for (key, value) in overlay {
            merged[key] = value
        }
        return values(from: merged)
    }

    public static func provenance(
        for field: MkxpEngineField,
        stateDirectory: URL
    ) -> MkxpValueProvenance {
        overlayDefines(field, in: stateDirectory) ? .yours : .game
    }

    public static func overlayDefines(_ field: MkxpEngineField, in stateDirectory: URL) -> Bool {
        guard let overlay = loadOverlayDict(from: stateDirectory) else { return false }
        switch field {
        case .smoothScaling:
            return overlay["smoothScaling"] != nil
        case .fixedAspectRatio:
            return overlay["fixedAspectRatio"] != nil
        case .renderScale:
            return overlay["enableHires"] != nil || overlay["framebufferScalingFactor"] != nil
        case .frameSkip:
            return overlay["frameSkip"] != nil
        case .vsync:
            return overlay["syncToRefreshrate"] != nil || overlay["vsync"] != nil
        case .pathCache:
            return overlay["pathCache"] != nil
        case .fontScale:
            return overlay["fontScale"] != nil
        case .solidFonts:
            return overlay["solidFonts"] != nil
        }
    }

    public static func readManaged(from stateDirectory: URL) -> MkxpEngineValues {
        readOverlay(from: stateDirectory)
    }

    public static func readGameDefaults(from gameDirectory: URL) -> MkxpGameDefaults {
        let sourceURL = devConfigURL(in: gameDirectory)
        guard let raw = try? String(contentsOf: sourceURL, encoding: .utf8),
            let config = parseJSONWithComments(raw)
        else {
            return MkxpGameDefaults()
        }
        let values = values(from: config)
        return MkxpGameDefaults(
            smoothScaling: values.smoothScaling,
            fixedAspectRatio: values.fixedAspectRatio,
            renderScaleEnableHires: values.renderScaleEnableHires,
            renderScaleFramebufferFactor: values.renderScaleFramebufferFactor,
            frameSkip: values.frameSkip,
            vsync: values.vsync,
            pathCache: values.pathCache,
            fontScale: values.fontScale,
            solidFonts: values.solidFonts
        )
    }

    // MARK: - Overlay string for engine bridge

    /// JSON object string handed to `mkxp_setConfigOverlayJSON`, or nil
    /// when there is nothing to send (no overlay keys and no host
    /// normalization patches apply).
    public static func overlayJSONString(
        gameDirectory: URL,
        stateDirectory: URL,
        onUnparseableOverlay: ((String) -> Void)? = nil
    ) -> String? {
        let overlayURL = overlayConfigURL(in: stateDirectory)
        var overlay: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: overlayURL.path) {
            if let raw = try? String(contentsOf: overlayURL, encoding: .utf8) {
                if let parsed = parseJSONWithComments(raw) {
                    overlay = parsed
                } else {
                    onUnparseableOverlay?(
                        "ManagedMkxpConfig: unparseable EmpoState/mkxp.json; treating overlay as absent"
                    )
                }
            }
        }

        let baseExists = FileManager.default.fileExists(
            atPath: devConfigURL(in: gameDirectory).path)
        let base = loadBaseDict(from: gameDirectory)
        var patches: [String: Any] = [:]

        if let base {
            // Neutralize desktop window sizing only when the base
            // defines it, so a plain game sends no overlay at all.
            if base["defScreenW"] != nil { patches["defScreenW"] = NSNull() }
            if base["defScreenH"] != nil { patches["defScreenH"] = NSNull() }

            if base["vsync"] != nil,
                base["syncToRefreshrate"] == nil,
                overlay["syncToRefreshrate"] == nil,
                overlay["vsync"] == nil,
                let legacyVsync = base["vsync"] as? Bool
            {
                patches["syncToRefreshrate"] = legacyVsync
            }
        } else if baseExists {
            // The engine may parse a base the host cannot; neutralize
            // conservatively (null on an absent key is harmless).
            patches["defScreenW"] = NSNull()
            patches["defScreenH"] = NSNull()
        }

        guard !overlay.isEmpty || !patches.isEmpty else {
            return nil
        }

        // Overlay wins over patches: a hand-added overlay key (for
        // example an explicit defScreenW) is the user's call.
        var payload = patches
        for (key, value) in overlay {
            payload[key] = value
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    // MARK: - Overlay writes

    /// Write only the non-nil override fields into the sparse overlay.
    @discardableResult
    public static func writeOverlay(
        overrides: MkxpEngineValues,
        stateDirectory: URL
    ) -> Bool {
        var overlay = loadOverlayDict(from: stateDirectory) ?? [:]
        applyOverrides(overrides, to: &overlay)
        return persistOverlay(overlay, to: stateDirectory)
    }

    /// Back-compat name for overlay writes from Game Settings.
    @discardableResult
    public static func updateManaged(
        overrides: MkxpEngineValues,
        stateDirectory: URL,
        gameDirectory: URL
    ) -> Bool {
        _ = gameDirectory
        return writeOverlay(overrides: overrides, stateDirectory: stateDirectory)
    }

    /// Remove one engine field from the overlay (fall through to base).
    @discardableResult
    public static func resetField(
        _ field: MkxpEngineField,
        stateDirectory: URL,
        gameDirectory: URL
    ) -> Bool {
        _ = gameDirectory
        var overlay = loadOverlayDict(from: stateDirectory) ?? [:]
        clearField(field, in: &overlay)
        return persistOverlay(overlay, to: stateDirectory)
    }

    /// Reset every engine field (Reset to Defaults in Game Settings).
    @discardableResult
    public static func resetAllEngineFields(
        stateDirectory: URL,
        gameDirectory: URL
    ) -> Bool {
        _ = gameDirectory
        var overlay = loadOverlayDict(from: stateDirectory) ?? [:]
        for field in MkxpEngineField.allCases {
            clearField(field, in: &overlay)
        }
        return persistOverlay(overlay, to: stateDirectory)
    }

    // MARK: - Legacy migration

    public static func gameSettingsContainsLegacyEngineKeys(at stateDirectory: URL) -> Bool {
        let url = stateDirectory.appendingPathComponent(settingsFilename)
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return legacyGameSettingsKeys.contains { json[$0] != nil }
    }

    /// One-time migration: build a sparse overlay from legacy
    /// `game_settings.json` engine keys, replace `EmpoState/mkxp.json`,
    /// strip those keys from the sidecar.
    @discardableResult
    public static func migrateLegacyEngineSettingsIfNeeded(
        stateDirectory: URL,
        gameDirectory: URL
    ) -> Bool {
        _ = gameDirectory
        let settingsURL = stateDirectory.appendingPathComponent(settingsFilename)
        guard let data = try? Data(contentsOf: settingsURL),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return true
        }

        guard legacyGameSettingsKeys.contains(where: { json[$0] != nil }) else {
            return true
        }

        let overrides = legacyValues(from: json)
        guard writeSparseOverlay(overrides, to: stateDirectory) else {
            return false
        }

        for key in legacyGameSettingsKeys {
            json.removeValue(forKey: key)
        }
        guard let cleaned = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return false
        }
        do {
            try cleaned.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Internals

    private static func parseJSONWithComments(_ raw: String) -> [String: Any]? {
        JSON5LiteParser.parseObject(raw)
    }

    private static func loadBaseDict(from gameDirectory: URL) -> [String: Any]? {
        let devURL = devConfigURL(in: gameDirectory)
        guard FileManager.default.fileExists(atPath: devURL.path),
            let raw = try? String(contentsOf: devURL, encoding: .utf8),
            let parsed = parseJSONWithComments(raw)
        else {
            return nil
        }
        return parsed
    }

    private static func loadOverlayDict(from stateDirectory: URL) -> [String: Any]? {
        let overlayURL = overlayConfigURL(in: stateDirectory)
        guard FileManager.default.fileExists(atPath: overlayURL.path),
            let raw = try? String(contentsOf: overlayURL, encoding: .utf8),
            let parsed = parseJSONWithComments(raw)
        else {
            return nil
        }
        return parsed
    }

    @discardableResult
    private static func writeSparseOverlay(
        _ overrides: MkxpEngineValues,
        to stateDirectory: URL
    ) -> Bool {
        var overlay: [String: Any] = [:]
        applyOverrides(overrides, to: &overlay)
        return persistOverlay(overlay, to: stateDirectory)
    }

    // UI writes touch only their own keys; anything else a user put in
    // the overlay by hand is preserved.
    @discardableResult
    private static func persistOverlay(
        _ overlay: [String: Any],
        to stateDirectory: URL
    ) -> Bool {
        let url = overlayConfigURL(in: stateDirectory)
        if overlay.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        return writeConfig(overlay, to: url)
    }

    private static func applyOverrides(
        _ overrides: MkxpEngineValues,
        to config: inout [String: Any],
        only fields: Set<MkxpEngineField>? = nil
    ) {
        let applyAll = fields == nil
        func shouldApply(_ field: MkxpEngineField) -> Bool {
            applyAll || fields?.contains(field) == true
        }

        if shouldApply(.smoothScaling), let v = overrides.smoothScaling {
            config["smoothScaling"] = v ? 1 : 0
        }
        if shouldApply(.fixedAspectRatio), let v = overrides.fixedAspectRatio {
            config["fixedAspectRatio"] = v
        }
        if shouldApply(.frameSkip), let v = overrides.frameSkip {
            config["frameSkip"] = v
        }
        if shouldApply(.fontScale), let v = overrides.fontScale {
            config["fontScale"] = v
        }
        if shouldApply(.vsync), let v = overrides.vsync {
            config.removeValue(forKey: "vsync")
            config["syncToRefreshrate"] = v
        }
        if shouldApply(.pathCache), let v = overrides.pathCache {
            config["pathCache"] = v
        }
        if shouldApply(.solidFonts), let v = overrides.solidFonts {
            config["solidFonts"] = v ? ["*"] : [] as [String]
        }
        if shouldApply(.renderScale) {
            if let enableHires = overrides.renderScaleEnableHires {
                if enableHires {
                    config["enableHires"] = true
                    if let factor = overrides.renderScaleFramebufferFactor {
                        config["framebufferScalingFactor"] = factor
                    }
                } else {
                    config["enableHires"] = false
                    config.removeValue(forKey: "framebufferScalingFactor")
                }
            }
        }
    }

    private static func clearField(_ field: MkxpEngineField, in config: inout [String: Any]) {
        switch field {
        case .smoothScaling:
            config.removeValue(forKey: "smoothScaling")
        case .fixedAspectRatio:
            config.removeValue(forKey: "fixedAspectRatio")
        case .renderScale:
            config.removeValue(forKey: "enableHires")
            config.removeValue(forKey: "framebufferScalingFactor")
        case .frameSkip:
            config.removeValue(forKey: "frameSkip")
        case .vsync:
            config.removeValue(forKey: "syncToRefreshrate")
            config.removeValue(forKey: "vsync")
        case .pathCache:
            config.removeValue(forKey: "pathCache")
        case .fontScale:
            config.removeValue(forKey: "fontScale")
        case .solidFonts:
            config.removeValue(forKey: "solidFonts")
        }
    }

    private static func values(from config: [String: Any]) -> MkxpEngineValues {
        let enableHires = config["enableHires"] as? Bool
        let scalingFactor =
            (config["framebufferScalingFactor"] as? Double)
            ?? (config["framebufferScalingFactor"] as? Int).map(Double.init)

        let solidFontsArray = config["solidFonts"] as? [String]
        let solidFontsEnabled: Bool? = solidFontsArray.map { !$0.isEmpty }

        return MkxpEngineValues(
            smoothScaling: (config["smoothScaling"] as? Int).map { $0 != 0 },
            fixedAspectRatio: config["fixedAspectRatio"] as? Bool,
            renderScaleEnableHires: enableHires,
            renderScaleFramebufferFactor: scalingFactor,
            frameSkip: config["frameSkip"] as? Bool,
            vsync: (config["syncToRefreshrate"] as? Bool)
                ?? (config["vsync"] as? Bool),
            pathCache: config["pathCache"] as? Bool,
            fontScale: config["fontScale"] as? Double,
            solidFonts: solidFontsEnabled
        )
    }

    private static func legacyValues(from json: [String: Any]) -> MkxpEngineValues {
        var renderEnableHires: Bool?
        var renderFactor: Double?
        if let scale = json["renderScale"] as? String {
            switch scale {
            case "x1":
                renderEnableHires = false
            case "x2":
                renderEnableHires = true
                renderFactor = 2.0
            case "x4":
                renderEnableHires = true
                renderFactor = 4.0
            default:
                break
            }
        }

        return MkxpEngineValues(
            smoothScaling: json["smoothScaling"] as? Bool,
            fixedAspectRatio: json["fixedAspectRatio"] as? Bool,
            renderScaleEnableHires: renderEnableHires,
            renderScaleFramebufferFactor: renderFactor,
            frameSkip: json["frameSkip"] as? Bool,
            vsync: json["vsync"] as? Bool,
            pathCache: json["pathCache"] as? Bool,
            fontScale: json["fontScale"] as? Double,
            solidFonts: json["solidFonts"] as? Bool
        )
    }

    @discardableResult
    private static func writeConfig(_ config: [String: Any], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        ),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            return false
        }
        do {
            try jsonString.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}

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

    // MARK: - Read

    public static func managedConfigURL(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent(configFilename)
    }

    public static func devConfigURL(in gameDirectory: URL) -> URL {
        gameDirectory.appendingPathComponent(configFilename)
    }

    /// True when `Game/mkxp.json` exists but cannot be parsed. Engine rows
    /// are read-only in this case and no managed copy is written.
    public static func isDevConfigUnparseable(gameDirectory: URL) -> Bool {
        let sourceURL = devConfigURL(in: gameDirectory)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return false }
        guard let raw = try? String(contentsOf: sourceURL, encoding: .utf8) else { return true }
        return parseJSONWithComments(raw) == nil
    }

    public static func readManaged(from stateDirectory: URL) -> MkxpEngineValues {
        let configURL = managedConfigURL(in: stateDirectory)
        guard let raw = try? String(contentsOf: configURL, encoding: .utf8),
            let config = parseJSONWithComments(raw)
        else {
            return MkxpEngineValues()
        }
        return values(from: config)
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

    // MARK: - Seed / project

    /// Project `Game/mkxp.json` into `EmpoState/mkxp.json` with the same
    /// normalizations the old per-boot projector applied. Returns `false`
    /// when the developer file exists but does not parse (no managed copy
    /// is written and any stale managed file is removed).
    @discardableResult
    public static func seed(from gameDirectory: URL, to stateDirectory: URL) -> Bool {
        project(
            devBaseFrom: gameDirectory,
            overrides: MkxpEngineValues(),
            to: stateDirectory
        )
    }

    /// Merge developer base + optional overrides into the managed config.
    /// Used for import-time JGP overlays and legacy migration.
    @discardableResult
    public static func project(
        devBaseFrom gameDirectory: URL,
        overrides: MkxpEngineValues,
        to stateDirectory: URL
    ) -> Bool {
        let configURL = managedConfigURL(in: stateDirectory)
        let sourceURL = devConfigURL(in: gameDirectory)

        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            guard let raw = try? String(contentsOf: sourceURL, encoding: .utf8),
                let parsed = parseJSONWithComments(raw)
            else {
                try? FileManager.default.removeItem(at: configURL)
                return false
            }
            config = parsed
        }

        applyNormalizations(to: &config)
        applyOverrides(overrides, to: &config)
        return writeConfig(config, to: configURL)
    }

    // MARK: - Read-modify-write

    /// Parse the managed config (or the developer base when missing),
    /// apply `overrides` for only the non-nil fields, and write back.
    @discardableResult
    public static func updateManaged(
        overrides: MkxpEngineValues,
        stateDirectory: URL,
        gameDirectory: URL
    ) -> Bool {
        if isDevConfigUnparseable(gameDirectory: gameDirectory) { return false }

        let configURL = managedConfigURL(in: stateDirectory)
        var config = loadManagedOrDevBase(stateDirectory: stateDirectory, gameDirectory: gameDirectory)
            ?? [:]
        applyNormalizations(to: &config)
        applyOverrides(overrides, to: &config)
        return writeConfig(config, to: configURL)
    }

    /// Reset one engine field to the game's default: copy the developer
    /// value when `Game/mkxp.json` defines it, otherwise remove the key.
    @discardableResult
    public static func resetField(
        _ field: MkxpEngineField,
        stateDirectory: URL,
        gameDirectory: URL,
        devDefaults: MkxpGameDefaults
    ) -> Bool {
        if isDevConfigUnparseable(gameDirectory: gameDirectory) { return false }

        let configURL = managedConfigURL(in: stateDirectory)
        var config = loadManagedOrDevBase(stateDirectory: stateDirectory, gameDirectory: gameDirectory)
            ?? [:]
        applyNormalizations(to: &config)
        clearField(field, in: &config)

        if devDefaults.defines(field) {
            let devValues = MkxpEngineValues(
                smoothScaling: devDefaults.smoothScaling,
                fixedAspectRatio: devDefaults.fixedAspectRatio,
                renderScaleEnableHires: devDefaults.renderScaleEnableHires,
                renderScaleFramebufferFactor: devDefaults.renderScaleFramebufferFactor,
                frameSkip: devDefaults.frameSkip,
                vsync: devDefaults.vsync,
                pathCache: devDefaults.pathCache,
                fontScale: devDefaults.fontScale,
                solidFonts: devDefaults.solidFonts
            )
            applyOverrides(devValues, to: &config, only: [field])
        }

        return writeConfig(config, to: configURL)
    }

    /// Reset every engine field (Reset to Defaults in Game Settings).
    @discardableResult
    public static func resetAllEngineFields(
        stateDirectory: URL,
        gameDirectory: URL,
        devDefaults: MkxpGameDefaults
    ) -> Bool {
        if isDevConfigUnparseable(gameDirectory: gameDirectory) { return false }

        let configURL = managedConfigURL(in: stateDirectory)
        var config = loadManagedOrDevBase(stateDirectory: stateDirectory, gameDirectory: gameDirectory)
            ?? [:]
        applyNormalizations(to: &config)

        for field in MkxpEngineField.allCases {
            clearField(field, in: &config)
            if devDefaults.defines(field) {
                let devValues = MkxpEngineValues(
                    smoothScaling: devDefaults.smoothScaling,
                    fixedAspectRatio: devDefaults.fixedAspectRatio,
                    renderScaleEnableHires: devDefaults.renderScaleEnableHires,
                    renderScaleFramebufferFactor: devDefaults.renderScaleFramebufferFactor,
                    frameSkip: devDefaults.frameSkip,
                    vsync: devDefaults.vsync,
                    pathCache: devDefaults.pathCache,
                    fontScale: devDefaults.fontScale,
                    solidFonts: devDefaults.solidFonts
                )
                applyOverrides(devValues, to: &config, only: [field])
            }
        }

        return writeConfig(config, to: configURL)
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

    /// One-time migration: project legacy `game_settings.json` engine keys
    /// into `EmpoState/mkxp.json`, then strip those keys from the sidecar.
    /// Idempotent when no legacy keys remain. Never deletes keys unless
    /// projection succeeds.
    @discardableResult
    public static func migrateLegacyEngineSettingsIfNeeded(
        stateDirectory: URL,
        gameDirectory: URL
    ) -> Bool {
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
        guard project(devBaseFrom: gameDirectory, overrides: overrides, to: stateDirectory) else {
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

    private static func loadManagedOrDevBase(
        stateDirectory: URL,
        gameDirectory: URL
    ) -> [String: Any]? {
        let managedURL = managedConfigURL(in: stateDirectory)
        if let raw = try? String(contentsOf: managedURL, encoding: .utf8),
            let parsed = parseJSONWithComments(raw)
        {
            return parsed
        }

        let devURL = devConfigURL(in: gameDirectory)
        guard FileManager.default.fileExists(atPath: devURL.path),
            let raw = try? String(contentsOf: devURL, encoding: .utf8),
            let parsed = parseJSONWithComments(raw)
        else {
            return nil
        }
        return parsed
    }

    private static func applyNormalizations(to config: inout [String: Any]) {
        config.removeValue(forKey: "syntaxTransform")
        config.removeValue(forKey: "defScreenW")
        config.removeValue(forKey: "defScreenH")

        if let legacyVsync = config["vsync"] as? Bool {
            if config["syncToRefreshrate"] == nil {
                config["syncToRefreshrate"] = legacyVsync
            }
            config.removeValue(forKey: "vsync")
        }
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

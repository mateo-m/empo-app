import Foundation

/// The eight engine settings Empo surfaces in Game Settings and stores
/// in `EmpoState/mkxp.json`. Keys match mkxp-z's config surface.
public struct MkxpEngineValues: Equatable, Sendable {
    public var smoothScaling: Bool?
    public var fixedAspectRatio: Bool?
    /// `nil` means native resolution (`enableHires` false, factor stripped).
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

/// mkxp-z's `dataPathOrg` / `dataPathApp` config values. On desktop
/// mkxp-z feeds these to `SDL_GetPrefPath(org, app)` to place the
/// game's writable data directory - for every game, with engine
/// defaults when the keys are absent - so two releases that resolve
/// to the same pair share saves. Empo mirrors that by mapping the
/// pair to a shared save location outside the per-game container
/// (see `DataDirectory` in the app target).
public struct MkxpDataPath: Equatable, Sendable {
    public var org: String?
    public var app: String?

    public init(org: String? = nil, app: String? = nil) {
        self.org = org
        self.app = app
    }

    /// True when the game (or the user overlay) declares either key.
    public var isDeclared: Bool { org != nil || app != nil }
}

extension MkxpDataPath {
    /// Path components of the shared data directory under the
    /// shared root (`Data/` in the app). Mirrors mkxp-z's
    /// `SDL_GetPrefPath` semantics for every game, declared keys
    /// or not: an org of `"."` (or blank) contributes no
    /// component, and a missing `dataPathApp` falls back to the
    /// game's INI title. Each component is sanitized into a safe
    /// single path component.
    ///
    /// Desktop mkxp-z's last resort is the literal `"mkxp-z"`,
    /// which on Empo would pool every title-less game into ONE
    /// shared directory - different games would then read and
    /// overwrite each other's `Game.rxdata`. The container folder
    /// name (unique per installed game, stable across updates of
    /// the same title) takes that place instead. `"mkxp-z"`
    /// remains only for callers with no folder name to give.
    public func sharedDirectoryComponents(
        iniTitleFallback: String?,
        folderNameFallback: String? = nil
    ) -> [String] {
        var components: [String] = []
        if let orgComponent = Self.folderComponent(org) {
            components.append(orgComponent)
        }
        components.append(
            Self.folderComponent(app)
                ?? Self.folderComponent(iniTitleFallback)
                ?? Self.folderComponent(folderNameFallback)
                ?? "mkxp-z"
        )
        return components
    }

    private static func folderComponent(_ raw: String?) -> String? {
        guard
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            trimmed != "."
        else { return nil }
        let sanitized = GameFolderName.sanitize(trimmed)
        // A value that sanitizes down to nothing ("...", "///")
        // contributes no component instead of the sanitizer's
        // literal fallback name. The fallback chain (INI title,
        // then "mkxp-z") picks the actual directory.
        guard
            sanitized != GameFolderName.fallback
                || trimmed.caseInsensitiveCompare(GameFolderName.fallback) == .orderedSame
        else { return nil }
        return sanitized
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

/// Tells whether the effective value of an engine setting comes from
/// the game base (`Game/mkxp.json` or the engine default) or from
/// the user's overlay.
public enum MkxpValueProvenance: Equatable, Sendable {
    case game
    case yours
}

/// Keys that lived in `game_settings.json` before the mkxp accessor
/// migration. The one-time migration uses them. The migration is
/// safe to repeat.
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

    /// True when `Game/mkxp.json` exists but does not parse. Only UI
    /// annotations use this. The engine still reads the base file
    /// itself.
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

    /// The effective values after the merge of `Game/mkxp.json` and
    /// the overlay.
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

    /// `dataPathOrg` / `dataPathApp` after the usual merge of
    /// `Game/mkxp.json` and the `EmpoState/mkxp.json` overlay
    /// (overlay wins). Blank or non-string values read as absent.
    public static func readDataPath(
        stateDirectory: URL,
        gameDirectory: URL
    ) -> MkxpDataPath {
        var merged = loadBaseDict(from: gameDirectory) ?? [:]
        for (key, value) in loadOverlayDict(from: stateDirectory) ?? [:] {
            merged[key] = value
        }
        return MkxpDataPath(
            org: nonEmptyString(merged["dataPathOrg"]),
            app: nonEmptyString(merged["dataPathApp"])
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    /// The JSON object string that goes to `mkxp_setConfigOverlayJSON`,
    /// or nil when there is nothing to send (no overlay keys, and no
    /// host normalization patches apply).
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
                        "ManagedMkxpConfig: cannot read EmpoState/mkxp.json, treating the overlay as absent"
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
            // defines it. A plain game then sends no overlay at all.
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
            // The engine can parse a base that the host cannot. In
            // that case, neutralize both keys as a safe default. A
            // null on an absent key is harmless.
            patches["defScreenW"] = NSNull()
            patches["defScreenH"] = NSNull()
        }

        guard !overlay.isEmpty || !patches.isEmpty else {
            return nil
        }

        // The overlay wins over the patches: a hand-added overlay key
        // (for example, an explicit defScreenW) is the user's call.
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

    /// Writes only the non-nil override fields into the sparse overlay.
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

    /// Removes one engine field from the overlay. The value then
    /// falls through to the base.
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

    /// Resets every engine field (Reset to Defaults in Game Settings).
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

    /// One-time migration. Build a sparse overlay from the legacy
    /// `game_settings.json` engine keys. Replace `EmpoState/mkxp.json`.
    /// Strip those keys from the sidecar.
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

    // UI writes touch only their own keys. Anything else that the
    // user put in the overlay by hand stays intact.
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

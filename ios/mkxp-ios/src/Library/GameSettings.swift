import Foundation

// MARK: - Resolution Presets

struct ResolutionPreset: Identifiable, Hashable, Codable {
    let width: Int
    let height: Int

    var id: String { "\(width)x\(height)" }

    var label: String {
        "\(width) x \(height)"
    }

    var aspectRatio: String {
        let g = gcd(width, height)
        return "\(width / g):\(height / g)"
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }

    static let presets: [ResolutionPreset] = [
        .init(width: 512,  height: 384),
        .init(width: 512,  height: 768),
        .init(width: 544,  height: 416),
        .init(width: 640,  height: 480),
        .init(width: 800,  height: 600),
        .init(width: 1024, height: 768),
        .init(width: 1280, height: 720),
        .init(width: 1280, height: 960),
        .init(width: 1920, height: 1080),
    ]
}

// MARK: - Vertical Alignment

enum VerticalAlignment: String, Codable, CaseIterable {
    case top
    case topCenter
    case center

    var label: String {
        switch self {
        case .top: "Top"
        case .topCenter: "Top-center"
        case .center: "Center"
        }
    }

    /// Bridge value matching MKXPVerticalAlignment in ios_bridge.h
    var bridgeValue: MKXPVerticalAlignment {
        switch self {
        case .top: MKXP_VALIGN_TOP
        case .topCenter: MKXP_VALIGN_TOP_CENTER
        case .center: MKXP_VALIGN_CENTER
        }
    }
}

// MARK: - Game Settings

/// Per-game settings that override values in mkxp.json.
/// Stored as `ios_settings.json` in each game's directory.
/// All fields are optional — nil means "use game/engine default".
struct GameSettings: Codable {
    // Display
    var smoothScaling: Bool?           // true = bilinear (1), false = pixel-perfect (0)
    var fixedAspectRatio: Bool?        // true = letterbox, false = stretch-to-fill
    var resolution: ResolutionPreset?  // custom defScreenW/defScreenH
    var verticalAlignment: VerticalAlignment? // portrait screen alignment

    // Performance
    var frameSkip: Bool?               // skip rendering frames when behind
    var speedMultiplier: Int?          // game speed multiplier (1-9, nil = 1x normal)
    var vsync: Bool?                   // vertical sync
    var pathCache: Bool?               // index files with lowercase paths

    // Text
    var fontScale: Double?             // global font size multiplier (1.0 = default)
    var solidFonts: Bool?              // don't use alpha blending for text

    // Engine
    var postloadScripts: Bool?         // execute postload scripts for common fixes

    // MARK: - File Names

    private static let settingsFilename = "ios_settings.json"
    private static let originalConfigFilename = "mkxp.original.json"
    private static let configFilename = "mkxp.json"
    private static let cheatsFilename = "configuration.json"

    // MARK: - Load / Save

    /// Loads settings from the game directory. Returns empty settings if file doesn't exist.
    static func load(from gameDirectory: URL) -> GameSettings {
        let url = gameDirectory.appendingPathComponent(settingsFilename)
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(GameSettings.self, from: data) else {
            return GameSettings()
        }
        return settings
    }

    /// Saves settings to the game directory.
    func save(to gameDirectory: URL) {
        let url = gameDirectory.appendingPathComponent(Self.settingsFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Cheats (separate file)

    /// Reads the cheats flag from configuration.json in the game directory.
    static func loadCheats(from gameDirectory: URL) -> Bool {
        let url = gameDirectory.appendingPathComponent(cheatsFilename)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["cheats"] as? Bool ?? false
    }

    /// Writes the cheats flag to configuration.json in the game directory.
    static func saveCheats(_ value: Bool, to gameDirectory: URL) {
        let url = gameDirectory.appendingPathComponent(cheatsFilename)
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        json["cheats"] = value
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Config Merging

    /// Reads the game's mkxp.json default values for display in the settings UI.
    /// Falls back to the original backup if it exists (so we always show the
    /// game developer's intended defaults, not previously-merged values).
    static func readGameDefaults(from gameDirectory: URL) -> GameConfigDefaults {
        let originalURL = gameDirectory.appendingPathComponent(originalConfigFilename)
        let configURL = gameDirectory.appendingPathComponent(configFilename)

        // Prefer original backup (game developer's values) over merged config
        let sourceURL = FileManager.default.fileExists(atPath: originalURL.path)
            ? originalURL : configURL

        guard let raw = try? String(contentsOf: sourceURL, encoding: .utf8),
              let config = parseJSONWithComments(raw) else {
            return GameConfigDefaults()
        }

        // Read resolution from defScreenW/defScreenH
        let resW = config["defScreenW"] as? Int
        let resH = config["defScreenH"] as? Int
        let resolution: ResolutionPreset? = if let w = resW, let h = resH, w > 0, h > 0 {
            ResolutionPreset(width: w, height: h)
        } else {
            nil
        }

        // solidFonts is an array of font names in mkxp.json; treat non-empty as "enabled"
        let solidFontsArray = config["solidFonts"] as? [Any]
        let solidFontsEnabled: Bool? = solidFontsArray.map { !$0.isEmpty }

        return GameConfigDefaults(
            smoothScaling: (config["smoothScaling"] as? Int).map { $0 != 0 },
            fixedAspectRatio: config["fixedAspectRatio"] as? Bool,
            resolution: resolution,
            frameSkip: config["frameSkip"] as? Bool,
            vsync: config["vsync"] as? Bool,
            pathCache: config["pathCache"] as? Bool,
            fontScale: config["fontScale"] as? Double,
            solidFonts: solidFontsEnabled
        )
    }

    /// Merges these settings into the game's mkxp.json for the engine to read.
    /// Backs up the original config on first call so we can always revert.
    func applyToConfig(in gameDirectory: URL) {
        let configURL = gameDirectory.appendingPathComponent(Self.configFilename)
        let originalURL = gameDirectory.appendingPathComponent(Self.originalConfigFilename)

        // Back up original config on first encounter
        if !FileManager.default.fileExists(atPath: originalURL.path),
           FileManager.default.fileExists(atPath: configURL.path) {
            try? FileManager.default.copyItem(at: configURL, to: originalURL)
        }

        // Read the original config as base (preserves game developer's values for
        // keys we don't override). If no original exists, read the current config.
        let sourceURL = FileManager.default.fileExists(atPath: originalURL.path)
            ? originalURL : configURL

        var config: [String: Any] = [:]
        if let raw = try? String(contentsOf: sourceURL, encoding: .utf8),
           let parsed = Self.parseJSONWithComments(raw) {
            config = parsed
        }

        // Apply overrides — only non-nil values are written
        if let v = smoothScaling { config["smoothScaling"] = v ? 1 : 0 }
        if let v = fixedAspectRatio { config["fixedAspectRatio"] = v }
        if let v = frameSkip { config["frameSkip"] = v }
        if let v = fontScale { config["fontScale"] = v }
        if let v = vsync { config["vsync"] = v }
        if let v = pathCache { config["pathCache"] = v }

        // Resolution
        if let res = resolution {
            config["defScreenW"] = res.width
            config["defScreenH"] = res.height
        }

        // Solid fonts: mkxp.json expects an array of font names.
        // When enabled via toggle, apply to all fonts with a wildcard entry.
        if let v = solidFonts {
            config["solidFonts"] = v ? ["*"] : [] as [Any]
        }

        // Speed multiplier: compute fixedFramerate = 60 * multiplier.
        // Most games (especially Pokemon fan games) run at 60 FPS regardless
        // of RGSS version, since game scripts typically override the default.
        if let speed = speedMultiplier, speed > 1 {
            config["fixedFramerate"] = 60 * speed
        }

        // Write merged config (clean JSON without comments)
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            try? jsonString.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    /// Whether any config-level setting has been customized (for "Reset to Defaults" visibility).
    var hasCustomizations: Bool {
        smoothScaling != nil || fixedAspectRatio != nil || resolution != nil ||
        frameSkip != nil || speedMultiplier != nil || vsync != nil || pathCache != nil ||
        fontScale != nil || solidFonts != nil || postloadScripts != nil ||
        verticalAlignment != nil
    }

    // MARK: - JSON Helpers

    /// Parses a JSON string that may contain `//` line comments (as used by mkxp.json).
    static func parseJSONWithComments(_ raw: String) -> [String: Any]? {
        // Strip // comments (but not inside strings)
        var cleaned = ""
        var inString = false
        var escaped = false
        var i = raw.startIndex

        while i < raw.endIndex {
            let c = raw[i]

            if escaped {
                cleaned.append(c)
                escaped = false
                i = raw.index(after: i)
                continue
            }

            if c == "\\" && inString {
                cleaned.append(c)
                escaped = true
                i = raw.index(after: i)
                continue
            }

            if c == "\"" {
                inString.toggle()
                cleaned.append(c)
                i = raw.index(after: i)
                continue
            }

            if !inString && c == "/" {
                let next = raw.index(after: i)
                if next < raw.endIndex && raw[next] == "/" {
                    // Skip to end of line
                    while i < raw.endIndex && raw[i] != "\n" {
                        i = raw.index(after: i)
                    }
                    continue
                }
            }

            cleaned.append(c)
            i = raw.index(after: i)
        }

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}

// MARK: - Game Config Defaults

/// Values read from the game's mkxp.json (the developer's intended defaults).
/// Used by the settings UI to show the effective value when no override is set.
struct GameConfigDefaults {
    var smoothScaling: Bool?
    var fixedAspectRatio: Bool?
    var resolution: ResolutionPreset?
    var frameSkip: Bool?
    var vsync: Bool?
    var pathCache: Bool?
    var fontScale: Double?
    var solidFonts: Bool?

    // Engine defaults (used when neither game config nor user override is set)
    static let engineSmoothScaling = false
    static let engineFixedAspectRatio = true
    static let engineFrameSkip = false
    static let engineVsync = false
    static let enginePathCache = true
    static let engineFontScale = 1.0
    static let engineSolidFonts = false
    static let enginePostloadScripts = true
    static let engineVerticalAlignment = VerticalAlignment.topCenter
}

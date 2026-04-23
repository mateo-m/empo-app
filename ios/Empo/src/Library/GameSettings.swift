import Foundation


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

    var bridgeValue: MKXPVerticalAlignment {
        switch self {
        case .top: MKXP_VALIGN_TOP
        case .topCenter: MKXP_VALIGN_TOP_CENTER
        case .center: MKXP_VALIGN_CENTER
        }
    }
}


/// Per-game settings stored as `game_settings.json` in each game directory.
/// All fields are optional - nil means "use game/engine default".
struct GameSettings: Codable, Equatable {
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
    // Nil = default (Ruby 1.8 compat for max PE fangame compatibility).
    // True = disable syntaxTransform so the engine runs pure Ruby 3.
    // Needed for games that ship Ruby-3-era scripts (keyword-arg
    // hash shorthand, numbered block params, etc.) - notably Pokemon
    // Reborn 19.5+, PE v20+, and any game packaged for the mkxp-z
    // runtime. Detected automatically during JGP import by scanning
    // .rb scripts for Ruby-3-only syntax, but users can also flip
    // this manually per game if the heuristic misses.
    var useModernRuby: Bool?


    private static let settingsFilename = "game_settings.json"
    private static let originalConfigFilename = "mkxp.original.json"
    private static let configFilename = "mkxp.json"
    private static let cheatsFilename = "configuration.json"


    static func load(from gameDirectory: URL) -> GameSettings {
        let url = gameDirectory.appendingPathComponent(settingsFilename)
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(GameSettings.self, from: data) else {
            return GameSettings()
        }
        return settings
    }

    func save(to gameDirectory: URL) {
        let url = gameDirectory.appendingPathComponent(Self.settingsFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }


    static func loadCheats(from gameDirectory: URL) -> Bool {
        let url = gameDirectory.appendingPathComponent(cheatsFilename)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["cheats"] as? Bool ?? false
    }

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


    /// Scans a freshly-imported game folder for Ruby 3-only syntax
    /// markers and returns true if any are found. Used by the
    /// import pipeline to set `useModernRuby` so the engine runs
    /// without the Ruby 1.8 compat transform for games that ship
    /// modern Ruby source (Reborn 19.5+, PE v20+, mkxp-z JGPs).
    ///
    /// Heuristic-only: looks for keyword-arg shorthand
    /// (`id: -1,`, `foo: "bar",`) anywhere inside `.rb` files at
    /// the game root or `Scripts/` subfolder. The 1.8-era syntax
    /// for the same idea is `:id => -1`, so the `key: value,`
    /// form is a strong Ruby-3 signal. False positives on comments
    /// or strings containing that pattern are possible but rare
    /// and have no ill effect - disabling the transform on a 1.8
    /// game still runs it as Ruby 3, which works for everything
    /// except legacy constructs the transform would have rewritten
    /// (and we can flip the setting manually afterwards).
    static func detectModernRubyScripts(in gameDirectory: URL) -> Bool {
        let fm = FileManager.default

        // Search depth is capped by the enumerator's defaults.
        // Stop at the first positive match to keep big fangames
        // from scanning thousands of files on import.
        let candidates = [
            gameDirectory,
            gameDirectory.appendingPathComponent("Scripts"),
            gameDirectory.appendingPathComponent("Data"),
        ]

        // Ruby 3 keyword-arg shorthand inside method calls. A word
        // followed by a colon and a literal value or variable, with
        // no `=>` rocket before it. Excludes YAML-style ":foo"
        // symbols by requiring the identifier BEFORE the colon.
        let modernRegex = try? NSRegularExpression(
            pattern: "\\n\\s*[a-z_][a-zA-Z0-9_]*:\\s+(-?\\d|\"|\\[|\\{|true|false|nil|:)",
            options: []
        )
        guard let regex = modernRegex else { return false }

        for root in candidates {
            guard fm.fileExists(atPath: root.path),
                  let enumerator = fm.enumerator(at: root,
                      includingPropertiesForKeys: nil,
                      options: [.skipsHiddenFiles])
            else { continue }

            var filesScanned = 0
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() != "rb" { continue }
                filesScanned += 1
                // Hard cap so a pathological game tree can't stall
                // the import pipeline.
                if filesScanned > 200 { break }

                guard let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }

                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }


    /// Reads the game's mkxp.json defaults. Prefers the original backup
    /// over merged config so the developer's intended values always show.
    static func readGameDefaults(from gameDirectory: URL) -> GameConfigDefaults {
        let originalURL = gameDirectory.appendingPathComponent(originalConfigFilename)
        let configURL = gameDirectory.appendingPathComponent(configFilename)

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
        let solidFontsArray = config["solidFonts"] as? [String]
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

    /// Merges these settings into the game's mkxp.json.
    /// Backs up the original config on first call so the change can be reverted.
    func applyToConfig(in gameDirectory: URL) {
        let configURL = gameDirectory.appendingPathComponent(Self.configFilename)
        let originalURL = gameDirectory.appendingPathComponent(Self.originalConfigFilename)

        if !FileManager.default.fileExists(atPath: originalURL.path),
           FileManager.default.fileExists(atPath: configURL.path) {
            try? FileManager.default.copyItem(at: configURL, to: originalURL)
        }

        // Preserves game developer's values for keys that aren't overridden
        let sourceURL = FileManager.default.fileExists(atPath: originalURL.path)
            ? originalURL : configURL

        var config: [String: Any] = [:]
        if let raw = try? String(contentsOf: sourceURL, encoding: .utf8),
           let parsed = Self.parseJSONWithComments(raw) {
            config = parsed
        }

        // Ruby compatibility mode. Most PE fangames are written in
        // Ruby 1.8 syntax and need `syntaxTransform: 2` so the
        // engine translates old forms (`when X:`, unparenthesized
        // method chains, legacy hash rockets, etc) before Ruby 3
        // parses them. Games targeting the modern `mkxp-z` runtime
        // - Reborn 19.5+, PE v20+, anything packaged as an mkxp-z
        // JGP - ship actual Ruby 3 source (keyword-arg shorthand
        // `id: -1`, `foo: "bar"`) which the 1.8 transform would
        // mis-parse. For those we explicitly disable the transform
        // by writing `syntaxTransform: 0`. The import-time detector
        // flips useModernRuby when it finds Ruby-3-only syntax.
        if let modern = useModernRuby, modern {
            config["syntaxTransform"] = 0
        } else if config["syntaxTransform"] == nil {
            config["syntaxTransform"] = 2
        }

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
            config["solidFonts"] = v ? ["*"] : [] as [String]
        }

        // Speed multiplier: compute fixedFramerate = 60 * multiplier.
        // Most games (especially Pokemon fan games) run at 60 FPS regardless
        // of RGSS version, since game scripts typically override the default.
        if let speed = speedMultiplier, speed > 1 {
            config["fixedFramerate"] = 60 * speed
        }

        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            try? jsonString.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    var hasCustomizations: Bool {
        self != GameSettings()
    }


    /// Parses JSON with `//` line comments (as used by mkxp.json).
    static func parseJSONWithComments(_ raw: String) -> [String: Any]? {
        // Normalize CRLF/CR to LF first. Swift treats `\r\n` as a single
        // grapheme cluster that never equals `"\n"`, which would make the
        // comment-skip loop below consume the rest of the file.
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")

        var cleaned = ""
        var inString = false
        var escaped = false
        var i = normalized.startIndex

        while i < normalized.endIndex {
            let c = normalized[i]

            if escaped {
                cleaned.append(c)
                escaped = false
                i = normalized.index(after: i)
                continue
            }

            if c == "\\" && inString {
                cleaned.append(c)
                escaped = true
                i = normalized.index(after: i)
                continue
            }

            if c == "\"" {
                inString.toggle()
                cleaned.append(c)
                i = normalized.index(after: i)
                continue
            }

            if !inString && c == "/" {
                let next = normalized.index(after: i)
                if next < normalized.endIndex && normalized[next] == "/" {
                    while i < normalized.endIndex && normalized[i] != "\n" {
                        i = normalized.index(after: i)
                    }
                    continue
                }
            }

            cleaned.append(c)
            i = normalized.index(after: i)
        }

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}


/// Values from the game's mkxp.json — the developer's intended defaults.
struct GameConfigDefaults {
    var smoothScaling: Bool?
    var fixedAspectRatio: Bool?
    var resolution: ResolutionPreset?
    var frameSkip: Bool?
    var vsync: Bool?
    var pathCache: Bool?
    var fontScale: Double?
    var solidFonts: Bool?

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

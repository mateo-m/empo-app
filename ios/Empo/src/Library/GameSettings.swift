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
    var speedMultiplier: Int?          // fast-forward multiplier (2-9, nil = disabled). Runtime-only, applied via PlayerMoreSheet's Fast forward toggle.
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

    // Force the Pokemon Essentials in-game keyboard scene for text
    // entry instead of the iOS soft keyboard. Default false (use
    // the soft keyboard, which works for IF / Reborn / Insurgence).
    // Flip on for games whose keyboard scene adds custom keys or
    // layouts that the iOS soft keyboard can't drive. Routes
    // through the `mkxp_setUseInGameKeyboard` bridge to
    // `pokemon_input.rb`'s `USEKEYBOARDTEXTENTRY = false` override.
    var useInGameKeyboard: Bool?


    private static let settingsFilename = "game_settings.json"
    private static let originalConfigFilename = "mkxp.original.json"
    private static let configFilename = "mkxp.json"


    /// Read the game's settings sidecar.
    ///
    /// `stateDirectory` is the per-game `<container>/EmpoState/`
    /// directory (typically obtained via `container.empoStateURL`),
    /// NOT the imported `Game/` subdir - settings live outside the
    /// game files so the imported tree stays pristine.
    static func load(from stateDirectory: URL) -> GameSettings {
        let url = stateDirectory.appendingPathComponent(settingsFilename)
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(GameSettings.self, from: data) else {
            return GameSettings()
        }
        return settings
    }

    /// Write the game's settings sidecar to
    /// `<container>/EmpoState/`.
    func save(to stateDirectory: URL) {
        let url = stateDirectory.appendingPathComponent(Self.settingsFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
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

        // Ruby-3 keyword-arg shorthand. A name followed by `:` and a
        // space then a literal/variable, NOT preceded by `:` (which
        // would make it a symbol literal) and NOT followed by `:`
        // (which would make it a constant like `Foo::Bar`).
        //
        // We match two call-sites:
        //   1. Start of a line (formatted kwargs):
        //        method_call(
        //          name: "bar",
        //          other: 123
        //        )
        //   2. Inline after `(` `,` or `{` (single-line kwargs):
        //        method_call(name: "bar", other: 123)
        //        { name: "bar" }
        //
        // The original detector only caught case 1, missing inline
        // calls like Infinite Fusion's `Game.save(safe: safesave)` on
        // a single line. That mis-flagged IF as a 1.8 game, leading
        // to `syntaxTransform: 2` being written and the engine
        // rejecting `safe:` as "unexpected ':'".
        //
        // The value side `(-?\d|...|[a-z])` admits a leading
        // lowercase identifier so that `safe: safesave` (value is a
        // local variable) matches too, not just literal values.
        let modernRegex = try? NSRegularExpression(
            pattern: "(?:^|(?<=[(,{]))\\s*[a-z_][a-zA-Z0-9_]*:\\s+(-?\\d|\"|'|\\[|\\{|true|false|nil|:[a-zA-Z_]|[a-z_])",
            options: [.anchorsMatchLines]
        )
        guard let regex = modernRegex else { return false }

        // Scan cap. The old limit of 200 tripped on Infinite Fusion
        // (541 .rb files scattered deep in `Data/Scripts/NNN_*/`),
        // causing the detector to miss the modern syntax and flip
        // `syntaxTransform` to 2 anyway. 2000 is plenty of headroom
        // for the largest PE fangames (Reborn ~1200, Rejuvenation
        // ~1500) without risking a slow import on a pathological
        // tree.
        let scanCap = 2000

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
                if filesScanned > scanCap { break }

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


    /// Best-effort "is this a Pokemon Essentials fangame?" detector.
    /// Used to set the default for `useInGameKeyboard` so PE games
    /// surface their built-in keyboard scene by default (PE 16-18
    /// era games don't handle the iOS soft-keyboard backspace path
    /// cleanly without our `pokemon_input.rb` shim, and the in-game
    /// scene's keyboard navigation is the more natural UX for
    /// those games anyway).
    ///
    /// Three signals, ANY-of. All require PE's actual code, data,
    /// or runtime presence so non-PE games can't false-positive
    /// simply by being Pokemon-themed (we deliberately do NOT
    /// title-match on "pokemon" / "poké" / "pokémon" since plenty
    /// of games reference the franchise by name without using PE
    /// under the hood):
    ///
    ///   1. Runtime marker `<stateDir>/.pokemon_essentials_detected`
    ///      written by `pokemon_input.rb` on a previous launch
    ///      when `$PokemonSystem` was defined. Catches PE games
    ///      whose scripts live inside an rgssad-encrypted archive
    ///      where signals 2 and 3 below can't see plaintext PE
    ///      identifiers. First launch falls through to signals 2/3
    ///      (and may default to OFF if those also miss); every
    ///      subsequent launch reads the marker and defaults ON.
    ///
    ///   2. `Data/Scripts.rxdata|rvdata|rvdata2` byte-contains a
    ///      PE script-name signature (`PokeBattle_*`,
    ///      `PokemonSystem`, `PokemonEntry`, `Compiler_PBS`).
    ///      Script names live in the marshaled rxdata array as
    ///      plain ASCII bytes - the source bodies are zlib-
    ///      compressed but the names aren't, so a raw byte search
    ///      works without a marshal decoder. Catches PE forks that
    ///      ship scripts in plaintext rxdata (Vinemon, Edelweiss
    ///      Chronicles, etc.).
    ///
    ///   3. `Data/` contains PE-style compiled PBS data shards
    ///      (`abilities.dat`, `species.dat`, `moves.dat`, etc.).
    ///      PE 19+ ships compiled PBS as `*.dat` files alongside
    ///      the rxdata; vanilla RGSS games don't ship these
    ///      specific filenames. Catches newer PE forks where the
    ///      scripts file is a small ScriptLoader stub and the bulk
    ///      of code lives in external `Data/Scripts/*.rb`.
    static func detectPokemonEssentials(in gameDirectory: URL,
                                        stateDirectory: URL) -> Bool {
        let fm = FileManager.default

        // Signal 1: runtime-detection marker from a prior launch.
        let marker = stateDirectory
            .appendingPathComponent(".pokemon_essentials_detected")
        if fm.fileExists(atPath: marker.path) { return true }

        // Signal 2: Scripts.rxdata byte-grep for PE script names.
        let scriptCandidates = [
            "Data/Scripts.rxdata",
            "Data/Scripts.rvdata",
            "Data/Scripts.rvdata2",
        ]
        let scriptSignatures: [Data] = [
            Data("PokeBattle".utf8),
            Data("PokemonSystem".utf8),
            Data("PokemonEntry".utf8),
            Data("Compiler_PBS".utf8),
        ]
        for relPath in scriptCandidates {
            let url = gameDirectory.appendingPathComponent(relPath)
            guard let data = try? Data(contentsOf: url), data.count > 1024
            else { continue }
            for sig in scriptSignatures {
                if data.range(of: sig) != nil { return true }
            }
        }

        // Signal 3: PE-style compiled PBS data files.
        let dataDir = gameDirectory.appendingPathComponent("Data")
        let peDataMarkers = [
            "abilities.dat", "species.dat", "moves.dat",
            "pokemon.dat", "pokemon_forms.dat", "items.dat",
            "trainer_types.dat", "encounters.dat",
        ]
        for marker in peDataMarkers {
            let url = dataDir.appendingPathComponent(marker)
            if fm.fileExists(atPath: url.path) { return true }
        }

        return false
    }


    /// Resolve the engine's `syntaxTransform` mode for this game.
    /// Honors an explicit `useModernRuby` setting; runs the .rb
    /// scanner when the setting is nil ("auto").
    ///
    /// Most PE fangames are written in Ruby 1.8 syntax and need
    /// the LEGACY transform so the engine rewrites old forms
    /// (`when X:`, unparenthesized method chains, legacy hash
    /// rockets, etc) before Ruby 3 parses them. Games targeting
    /// the modern mkxp-z runtime - Reborn 19.5+, PE v20+, anything
    /// packaged as an mkxp-z JGP - ship actual Ruby 3 source
    /// (keyword-arg shorthand `id: -1`, `foo: "bar"`) which the
    /// 1.8 transform would mis-parse, so we DISABLE the transform
    /// for those.
    ///
    /// Auto-detect runs the scanner at every launch so games
    /// imported before a scanner fix can recover. Concrete case:
    /// Infinite Fusion has 541 .rb files scattered in
    /// `Data/Scripts/NNN_*/` and uses inline keyword-args
    /// (`Game.save(safe: safesave)`); the original detector's
    /// 200-file cap + line-start-anchored regex missed it, so the
    /// game was stuck in LEGACY mode and Ruby 3.1 rejected `safe:`
    /// as "unexpected ':'". With the improved scanner run at
    /// launch, the mode flips to DISABLED and the game parses
    /// cleanly.
    func resolveSyntaxTransformMode(gameDirectory: URL) -> MKXPSyntaxTransformMode {
        let modern: Bool
        if let m = useModernRuby {
            modern = m
        } else {
            modern = Self.detectModernRubyScripts(in: gameDirectory)
        }
        return modern ? MKXP_SYNTAX_TRANSFORM_DISABLED
                      : MKXP_SYNTAX_TRANSFORM_LEGACY
    }


    /// Reads the game's mkxp.json defaults. Prefers the original backup
    /// over merged config so the developer's intended values always show.
    /// `stateDirectory` is the per-game `<container>/EmpoState/`
    /// where managed config files live (mkxp.json, mkxp.original.json)
    /// - NOT the imported `Game/` subdir.
    static func readGameDefaults(from stateDirectory: URL) -> GameConfigDefaults {
        let originalURL = stateDirectory.appendingPathComponent(originalConfigFilename)
        let configURL = stateDirectory.appendingPathComponent(configFilename)

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

    /// Merges these settings into the game's mkxp.json (in
    /// `<container>/EmpoState/`, not the imported `Game/` subdir).
    ///
    /// `stateDirectory` is the per-game state directory where
    /// mkxp.json + mkxp.original.json live; `gameDirectory` is the
    /// imported game folder (`<container>/Game/`), used only by the
    /// launch-time modern-Ruby detector that scans `.rb` script files.
    ///
    /// `mkxp.original.json` (the developer's shipped config, if any)
    /// is captured by `GameContainer.snapshotOriginalConfigIfNeeded`
    /// at launch time before `applyToConfig` runs - NOT here. An earlier
    /// version of this method had a lazy "copy current mkxp.json
    /// to mkxp.original.json on second launch if no .original.json
    /// existed" branch, which is structurally broken: by the second
    /// launch the state-dir mkxp.json is our own generated file,
    /// not the developer's, so the snapshot was a copy of our
    /// output rather than the developer's intent. The current flow
    /// snapshots from the game folder at launch and is idempotent
    /// (only copies when `<stateDir>/mkxp.original.json` doesn't
    /// already exist), which preserves the developer's values
    /// regardless of how many times we regenerate the state-dir
    /// mkxp.json from settings.
    func applyToConfig(stateDirectory: URL, gameDirectory: URL) {
        let configURL = stateDirectory.appendingPathComponent(Self.configFilename)
        let originalURL = stateDirectory.appendingPathComponent(Self.originalConfigFilename)

        // Preserves game developer's values for keys that aren't overridden
        let sourceURL = FileManager.default.fileExists(atPath: originalURL.path)
            ? originalURL : configURL

        var config: [String: Any] = [:]
        if let raw = try? String(contentsOf: sourceURL, encoding: .utf8),
           let parsed = Self.parseJSONWithComments(raw) {
            config = parsed
        }

        // syntaxTransform USED to be written here. It now travels via
        // the engine bridge (`mkxp_setSyntaxTransformMode`, called
        // from `AppState.selectGame` via
        // `resolveSyntaxTransformMode(gameDirectory:)`). Keeping
        // mkxp.json free of host-managed keys means
        // `mkxp.original.json` snapshots and the per-game-defaults
        // UI mirror the developer's intent only.
        //
        // Strip any stale syntaxTransform key carried over from
        // older Empo builds (or from a developer's mkxp.original.json
        // that happened to have one) so the merged config is clean.
        // The bridge value wins regardless, but cleaning the file
        // also keeps mkxp.json readable as documentation of what
        // the user/developer chose.
        config.removeValue(forKey: "syntaxTransform")

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

        // Speed multiplier moved from launch-time fixedFramerate to a
        // runtime fast-forward toggle (see PlayerMoreSheet +
        // mkxp_setFastForwardMultiplier). At game start the engine
        // paces normally; the user opts in via the in-game menu.
        // Nothing to write here.

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

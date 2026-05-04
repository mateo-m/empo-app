import Foundation


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
        case .x2: "Render at 2x the native size for sharper visuals on high-DPI screens."
        case .x4: "Render at 4x the native size. Sharpest, but uses more GPU."
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


// MARK: - Setting metadata wrappers
//
// Each `GameSettings` field is wrapped with `@Setting<T, RestartFlag>`
// or `@Setting<T, RuntimeFlag>`. The dirty-check below walks fields
// via Mirror reflection and consults each wrapper's flag, so adding
// a field forces the author to pick a category at the declaration
// site - no separate descriptor list to keep in sync.


/// Phantom-type tag for whether a field can re-apply mid-session
/// (runtime) or only at next launch (restart).
protocol SettingFlag {
    static var requiresRestart: Bool { get }
}

/// Engine reads this from `mkxp.json` once at RGSS thread startup.
/// Mid-session edits hit the JSON but the running engine keeps its
/// launch-time copy until the next quit.
enum RestartFlag: SettingFlag {
    static let requiresRestart = true
}

/// Field flows through a host bridge or is pure host-side rendering,
/// so edits apply on resume without a relaunch.
enum RuntimeFlag: SettingFlag {
    static let requiresRestart = false
}


/// Type-erased view of a `@Setting`-wrapped property. The dirty-check
/// uses this to ask whether a property requires restart and whether
/// its value differs from another instance's, without knowing the
/// concrete value type at compile time.
private protocol AnySetting {
    var requiresRestart: Bool { get }
    func anyEquals(_ other: Any) -> Bool
}


/// Per-field metadata carrier. `Flag` is a phantom type that encodes
/// the restart-required nature at compile time, so the JSON shape
/// stays identical to the un-wrapped form (one value per key, no
/// metadata in the encoded output).
@propertyWrapper
struct Setting<Value: Codable & Equatable, Flag: SettingFlag>: Codable, Equatable {
    var wrappedValue: Value

    init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.wrappedValue = try container.decode(Value.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.wrappedValue == rhs.wrappedValue
    }
}

extension Setting: AnySetting {
    var requiresRestart: Bool { Flag.requiresRestart }
    func anyEquals(_ other: Any) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}


/// Lets a `GameSettings` JSON file omit a wrapped optional field.
/// Swift's auto-synthesized `init(from:)` only treats missing keys
/// as nil for bare `Optional` properties, not wrapper-typed ones, so
/// new fields would throw "key not found" on first upgrade without
/// this.
extension KeyedDecodingContainer {
    func decode<V, F>(_ type: Setting<V?, F>.Type, forKey key: Key) throws -> Setting<V?, F>
    where V: Codable & Equatable, F: SettingFlag {
        if let value = try decodeIfPresent(type, forKey: key) {
            return value
        }
        return Setting(wrappedValue: nil)
    }
}


/// Per-game settings stored as `game_settings.json` in each game
/// directory. All fields are optional; nil means "use game/engine
/// default".
///
/// Each field carries `@Setting<..., RestartFlag>` or
/// `@Setting<..., RuntimeFlag>`. The dirty-check below uses the flag
/// to surface a "restart required" hint when the user edits a
/// launch-time field during an active session. When adding a field,
/// pick the flag that matches how the value reaches the engine:
/// `mkxp.json` at launch -> Restart; host bridge or rendering ->
/// Runtime.
struct GameSettings: Codable, Equatable {
    // Display
    /// true = bilinear (1), false = pixel-perfect (0)
    @Setting<Bool?, RestartFlag> var smoothScaling: Bool? = nil
    /// true = letterbox, false = stretch-to-fill
    @Setting<Bool?, RestartFlag> var fixedAspectRatio: Bool? = nil
    /// Render-buffer multiplier (1x / 2x / 4x). Maps to `enableHires`
    /// + `framebufferScalingFactor` in mkxp.json.
    @Setting<RenderScale?, RestartFlag> var renderScale: RenderScale? = nil
    /// portrait screen alignment - host-side rendering, no engine input
    @Setting<VerticalAlignment?, RuntimeFlag> var verticalAlignment: VerticalAlignment? = nil

    // Performance
    /// skip rendering frames when behind
    @Setting<Bool?, RestartFlag> var frameSkip: Bool? = nil
    /// fast-forward multiplier (2-9, nil = disabled). Runtime-only,
    /// applied via PlayerMoreSheet's Fast forward toggle through
    /// `mkxp_setFastForwardMultiplier`.
    @Setting<Int?, RuntimeFlag> var speedMultiplier: Int? = nil
    /// vertical sync (written as `syncToRefreshrate` in the merged
    /// mkxp.json - the engine ignores the legacy `vsync` key)
    @Setting<Bool?, RestartFlag> var vsync: Bool? = nil
    /// index files with lowercase paths
    @Setting<Bool?, RestartFlag> var pathCache: Bool? = nil

    // Text
    /// global font size multiplier (1.0 = default)
    @Setting<Double?, RestartFlag> var fontScale: Double? = nil
    /// don't use alpha blending for text
    @Setting<Bool?, RestartFlag> var solidFonts: Bool? = nil

    // Engine
    /// execute postload scripts for common fixes
    @Setting<Bool?, RestartFlag> var postloadScripts: Bool? = nil
    /// Legacy "skip the Ruby 1.8 compat transform" toggle, superseded
    /// by `rubyVersionOverride`. Kept for backward-compatible decoding
    /// of older `game_settings.json` files; the UI no longer surfaces
    /// it. Will go away once syntax-transform is dropped.
    @Setting<Bool?, RestartFlag> var useModernRuby: Bool? = nil

    /// Manual override for the per-game Ruby interpreter version.
    /// nil = use auto-detection from import; 18 / 19 / 30 / 31 forces
    /// that interpreter. Surfaced as the "Ruby version" picker in
    /// GameSettingsView and read by `AppState.selectGame` (calls
    /// `mkxp_setActiveRubyVersion()` before engine boot).
    ///
    /// Stored as Int so unknown values from a future Empo build don't
    /// break decoding. Restart-required because the active Ruby
    /// version is locked at app launch.
    @Setting<Int?, RestartFlag> var rubyVersionOverride: Int? = nil

    /// Force the Pokemon Essentials in-game keyboard scene for text
    /// entry instead of the iOS soft keyboard. Default false (the
    /// soft keyboard works for IF / Reborn / Insurgence). Flip on
    /// for games whose keyboard scene adds custom keys the soft
    /// keyboard can't drive. Routes through `mkxp_setUseInGameKeyboard`
    /// to `pokemon_input.rb`'s `USEKEYBOARDTEXTENTRY = false` override.
    @Setting<Bool?, RuntimeFlag> var useInGameKeyboard: Bool? = nil


    private static let settingsFilename = "game_settings.json"
    private static let configFilename = "mkxp.json"


    /// Read the game's settings sidecar from `<container>/EmpoState/`
    /// (NOT the imported `Game/` subdir; settings live outside the
    /// game files so the imported tree stays pristine).
    static func load(from stateDirectory: URL) -> GameSettings {
        let url = stateDirectory.appendingPathComponent(settingsFilename)
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(GameSettings.self, from: data) else {
            return GameSettings()
        }
        return settings
    }

    /// True if any `RestartFlag`-tagged field differs between `self`
    /// and `other`. The engine reads its config once at RGSS thread
    /// startup and never re-reads, so launch-time fields need a quit
    /// + relaunch; runtime fields apply on resume.
    func differsInRestartRequiredFields(from other: GameSettings) -> Bool {
        !restartRequiredFieldsChanged(from: other).isEmpty
    }


    /// User-facing labels of restart-required fields whose values
    /// differ between `self` and `other`. Feeds the restart-hint pill
    /// (e.g. "Smooth scaling and Render scale") instead of a generic
    /// "something changed". Order follows declaration order so the
    /// rendered list stays stable as the user toggles fields.
    func restartRequiredFieldsChanged(from other: GameSettings) -> [String] {
        let lhsChildren = Mirror(reflecting: self).children
        let rhsChildren = Mirror(reflecting: other).children
        var changed: [String] = []
        for (lhs, rhs) in zip(lhsChildren, rhsChildren) {
            guard let lhsSetting = lhs.value as? AnySetting,
                  let rhsSetting = rhs.value as? AnySetting
            else {
                // Bare properties bypass the dirty-check in release;
                // crash debug builds so a new field author gets nudged
                // to add `@Setting<..., Flag>`.
                assertionFailure(
                    "GameSettings.\(lhs.label ?? "<unknown>") missing @Setting wrapper - "
                    + "restart-hint logic can't see this field"
                )
                continue
            }
            guard lhsSetting.requiresRestart,
                  !lhsSetting.anyEquals(rhsSetting),
                  let label = lhs.label
            else { continue }
            changed.append(Self.displayLabel(forFieldLabel: label))
        }
        return changed
    }


    /// Maps a Mirror property label (rendered with a leading
    /// underscore by the property-wrapper machinery, e.g.
    /// `_smoothScaling`) to a user-facing label for the restart-hint
    /// pill. Hand-mapped switch instead of camelCase auto-formatting
    /// because the UI copy needs real review (acronyms like "VSync",
    /// multi-word phrases) and silent string drift on rename is worse
    /// than one entry per restart-required field.
    private static func displayLabel(forFieldLabel mirrorLabel: String) -> String {
        // Strip the leading underscore the property-wrapper machinery
        // prefixes onto Mirror labels.
        let key = mirrorLabel.hasPrefix("_")
            ? String(mirrorLabel.dropFirst())
            : mirrorLabel
        switch key {
        case "smoothScaling":     return "Smooth scaling"
        case "fixedAspectRatio":  return "Fixed aspect ratio"
        case "renderScale":       return "Render scale"
        case "frameSkip":         return "Frame skip"
        case "vsync":             return "VSync"
        case "pathCache":         return "Path cache"
        case "fontScale":         return "Font scale"
        case "solidFonts":        return "Solid fonts"
        case "postloadScripts":   return "Postload scripts"
        case "useModernRuby":     return "Ruby compatibility mode"
        default:
            // Surface the raw camelCase name so the missing mapping
            // is visible in the UI rather than silently dropped.
            assertionFailure("Missing displayLabel mapping for GameSettings.\(key)")
            return key
        }
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


    /// Returns true if a freshly-imported game folder looks like it
    /// runs on Ruby 3 (Reborn 19.5+, PE v20+, mkxp-z JGPs). Used
    /// during import to set `useModernRuby` so the engine skips the
    /// Ruby 1.8 compat transform.
    ///
    /// Three signals, ANY-of:
    ///
    /// 1. Bundled Ruby 3.x runtime, detected by binary content scan.
    ///    Modern custom engines ship their own Ruby (Pokemon Flux's
    ///    `x64-msvcrt-ruby310.dll`, macOS bundles' `libruby.3.x.dylib`).
    ///    We scan every `.dll`/`.dylib`/`.so` for the byte pattern
    ///    `"ruby 3."`. Robust to rename. Vanilla 1.8/1.9 binaries
    ///    embed `"ruby 1.8."` / `"ruby 1.9."` instead, so RGSS1/2/3
    ///    games don't false-positive (RGSS version and Ruby version
    ///    are independent).
    ///
    /// 2. `.fpk` packaging in `Data/`. The 7z archive format used by
    ///    post-2020 custom engines (Pokemon Flux mounts scripts from
    ///    `Data/Data_0.fpk` via `System.mount`). Vanilla RPG Maker
    ///    doesn't use .fpk. Catches games that statically linked
    ///    Ruby into the .exe and so escaped signal 1.
    ///
    /// 3. Loose `.rb` files with keyword-arg shorthand
    ///    (`id: -1,`, `foo: "bar",`). False positives on comments or
    ///    strings are rare; running a 1.8 game as Ruby 3 still works
    ///    for everything except legacy constructs the transform
    ///    would have rewritten, and the user can flip back manually.
    static func detectModernRubyScripts(in gameDirectory: URL) -> Bool {
        let fm = FileManager.default

        // Signal 1: scan native binaries for an embedded `"ruby 3."`
        // string. Capped at 64 MB per file; real Ruby DLLs are 5-15 MB,
        // anything bigger is unlikely to be Ruby.
        let modernRubyMarker = Data("ruby 3.".utf8)
        let scanBudget = 64 * 1024 * 1024
        for url in gameDirectory.directoryEntries(matchingExtensions: ["dll", "dylib", "so"], fm: fm) {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int,
                  size <= scanBudget,
                  let data = try? Data(contentsOf: url, options: .alwaysMapped)
            else { continue }
            if data.range(of: modernRubyMarker) != nil { return true }
        }

        // Signal 2: .fpk packaging. Modern custom engines mount
        // scripts from .fpk archives via `System.mount`; presence in
        // `Data/` is enough.
        let dataDir = gameDirectory.appendingPathComponent("Data")
        if !dataDir.directoryEntries(matchingExtensions: ["fpk"], fm: fm).isEmpty {
            return true
        }

        // Signal 3: loose .rb files with Ruby-3 keyword args. Depth
        // capped by the enumerator's defaults; stops at first match
        // to keep big fangames from scanning thousands of files.
        let candidates = [
            gameDirectory,
            gameDirectory.appendingPathComponent("Scripts"),
            dataDir,
        ]

        // Ruby-3 keyword-arg shorthand. A name followed by `:` and a
        // space then a literal/variable, NOT preceded by `:` (which
        // would make it a symbol literal) and NOT followed by `:` (a
        // constant like `Foo::Bar`).
        //
        // Matches two call sites:
        //   1. Start of a line (multi-line kwargs):
        //        method(
        //          name: "bar",
        //        )
        //   2. Inline after `(` `,` or `{` (single-line kwargs):
        //        method(name: "bar", other: 123)
        //
        // Originally only matched case 1, which missed inline calls
        // like IF's `Game.save(safe: safesave)` and mis-flagged the
        // game as Ruby 1.8.
        //
        // The value side `(-?\d|...|[a-z])` admits a leading lowercase
        // identifier so `safe: safesave` (variable, not literal) hits.
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
    /// just because they're Pokemon-themed (we deliberately do NOT
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


    /// Reads the game's mkxp.json defaults straight from the
    /// imported game folder. `gameDirectory` is the per-game
    /// `<container>/Game/` directory which is treated as immutable
    /// after import; Empo's managed config (`EmpoState/mkxp.json`)
    /// is generated from this source plus user overrides, never
    /// merged back. That makes `Game/mkxp.json` the developer's
    /// source-of-truth for the per-game-defaults UI.
    static func readGameDefaults(from gameDirectory: URL) -> GameConfigDefaults {
        let sourceURL = gameDirectory.appendingPathComponent(configFilename)

        guard let raw = try? String(contentsOf: sourceURL, encoding: .utf8),
              let config = parseJSONWithComments(raw) else {
            return GameConfigDefaults()
        }

        // Read render scale from enableHires + framebufferScalingFactor.
        // The legacy `defScreenW`/`defScreenH` keys are intentionally
        // ignored: they only sized the SDL window (irrelevant on
        // iOS) and never controlled the rendering buffer.
        let enableHires = config["enableHires"] as? Bool ?? false
        let scalingFactor = (config["framebufferScalingFactor"] as? Double)
            ?? (config["framebufferScalingFactor"] as? Int).map(Double.init)
            ?? 1.0
        let renderScale: RenderScale? = if enableHires {
            // Snap to the nearest supported step. Engine accepts
            // arbitrary doubles, but the UI only exposes 1/2/4 - so
            // a developer-shipped 3.0 reads back as "High (2x)" in
            // the defaults row.
            switch scalingFactor {
            case ..<1.5:  RenderScale.x1
            case ..<3.0:  RenderScale.x2
            default:      RenderScale.x4
            }
        } else {
            nil
        }

        // solidFonts is an array of font names in mkxp.json; treat non-empty as "enabled"
        let solidFontsArray = config["solidFonts"] as? [String]
        let solidFontsEnabled: Bool? = solidFontsArray.map { !$0.isEmpty }

        return GameConfigDefaults(
            smoothScaling: (config["smoothScaling"] as? Int).map { $0 != 0 },
            fixedAspectRatio: config["fixedAspectRatio"] as? Bool,
            renderScale: renderScale,
            frameSkip: config["frameSkip"] as? Bool,
            // mkxp-z controls vsync via
            // `syncToRefreshrate`. The legacy `vsync` field exists in
            // the parsed Config struct but is read by no rendering
            // code, so writing it has no effect. Read both for
            // backward-compat with hand-authored configs that used
            // the old key, but prefer `syncToRefreshrate`.
            vsync: (config["syncToRefreshrate"] as? Bool)
                ?? (config["vsync"] as? Bool),
            pathCache: config["pathCache"] as? Bool,
            fontScale: config["fontScale"] as? Double,
            solidFonts: solidFontsEnabled
        )
    }

    /// Generate the game's managed mkxp.json (in
    /// `<container>/EmpoState/`) by merging the developer's
    /// untouched `Game/mkxp.json` (if present) with these settings.
    ///
    /// `stateDirectory` is the per-game state directory (where the
    /// merged mkxp.json is written). `gameDirectory` is the
    /// imported `<container>/Game/` folder, which Empo treats as
    /// immutable after import; so reading the developer's source
    /// directly from `gameDirectory/mkxp.json` is safe and removes
    /// the need for the historic `mkxp.original.json` snapshot.
    func applyToConfig(stateDirectory: URL, gameDirectory: URL) {
        let configURL = stateDirectory.appendingPathComponent(Self.configFilename)
        let sourceURL = gameDirectory.appendingPathComponent(Self.configFilename)

        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: sourceURL.path),
           let raw = try? String(contentsOf: sourceURL, encoding: .utf8),
           let parsed = Self.parseJSONWithComments(raw) {
            config = parsed
        }

        // Host-managed keys travel via engine bridges, NOT through
        // mkxp.json:
        //   - syntaxTransform: mkxp_setSyntaxTransformMode
        //   - fast-forward: mkxp_setFastForwardMultiplier
        // Strip any leftovers in the developer's source so the
        // merged config stays a clean mirror of host overrides on
        // top of developer intent.
        config.removeValue(forKey: "syntaxTransform")

        if let v = smoothScaling { config["smoothScaling"] = v ? 1 : 0 }
        if let v = fixedAspectRatio { config["fixedAspectRatio"] = v }
        if let v = frameSkip { config["frameSkip"] = v }
        if let v = fontScale { config["fontScale"] = v }
        // mkxp-z's vsync is gated by `syncToRefreshrate`, not the
        // dead `vsync` field. Strip the legacy key so the merged
        // config doesn't carry unused state.
        config.removeValue(forKey: "vsync")
        if let v = vsync { config["syncToRefreshrate"] = v }
        if let v = pathCache { config["pathCache"] = v }

        // Render scale: mapped to mkxp-z's `enableHires` +
        // `framebufferScalingFactor`. The legacy `defScreenW`/
        // `defScreenH` keys are stripped from the merged config so
        // existing imports lose the dead state on next save - those
        // only sized the SDL window (irrelevant on iOS, which is
        // always fullscreen) and never controlled the rendering
        // buffer.
        config.removeValue(forKey: "defScreenW")
        config.removeValue(forKey: "defScreenH")
        if let scale = renderScale {
            if scale.enableHires {
                config["enableHires"] = true
                config["framebufferScalingFactor"] = scale.framebufferScalingFactor
            } else {
                // x1 - explicitly disable hires so a developer's
                // `enableHires=true` from Game/mkxp.json doesn't
                // leak into the merged config when the user picks
                // "Default".
                config["enableHires"] = false
                config.removeValue(forKey: "framebufferScalingFactor")
            }
        }

        // Solid fonts: mkxp.json expects an array of font names.
        // When enabled via toggle, apply to all fonts with a wildcard entry.
        if let v = solidFonts {
            config["solidFonts"] = v ? ["*"] : [] as [String]
        }

        // speedMultiplier is now runtime-only (PlayerMoreSheet's
        // Fast forward toggle calls mkxp_setFastForwardMultiplier).
        // Game launches at default speed; the user opts in via the
        // in-game menu. Nothing to write here.

        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            try? jsonString.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    var hasCustomizations: Bool {
        self != GameSettings()
    }


    /// Parses mkxp.json (which can have `//` comments). Thin
    /// wrapper around `JSON5LiteParser` kept for call-site brevity.
    static func parseJSONWithComments(_ raw: String) -> [String: Any]? {
        JSON5LiteParser.parseObject(raw)
    }
}


/// Values from the game's mkxp.json; the developer's intended defaults.
struct GameConfigDefaults {
    var smoothScaling: Bool?
    var fixedAspectRatio: Bool?
    var renderScale: RenderScale?
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
    static let engineRenderScale = RenderScale.x1
    static let engineVerticalAlignment = VerticalAlignment.topCenter
}

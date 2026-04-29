import Foundation


/// Render-resolution multiplier applied via mkxp-z's `enableHires`
/// + `framebufferScalingFactor`. RGSS games render to a buffer
/// whose dimensions are baked into the developer's scripts (544x416
/// for RGSS3, 640x480 for RGSS1), and that buffer's aspect ratio is
/// non-negotiable without breaking the game's own UI layout. What
/// the host CAN do is render that buffer at a higher pixel count
/// before downscaling to the iOS screen, which sharpens lines and
/// text on retina displays.
///
/// Earlier iterations exposed an absolute-dimension picker
/// ("1920x1080", "1280x720", etc.) that wrote `defScreenW` and
/// `defScreenH` to mkxp.json. Those keys only sized the SDL window
/// (irrelevant on iOS - always fullscreen), not the rendering
/// buffer, so the picker was misleading: users selecting "1920x1080"
/// got identical pixels to "Default". `RenderScale` is the honest
/// replacement.
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
// Each `GameSettings` field carries a "does changing this require a
// game relaunch?" flag inline with its declaration via
// `@Setting<T, RestartFlag>` or `@Setting<T, RuntimeFlag>`. The
// dirty-check at the bottom of `GameSettings` walks fields via
// Mirror reflection and consults each wrapper's flag, so adding a
// new field forces the author to pick a category at the
// declaration site - no separate descriptor list to keep in sync.


/// Phantom-type tag indicating whether a wrapped field is
/// mid-session re-applicable (runtime) or only honored at next
/// engine launch (restart).
protocol SettingFlag {
    static var requiresRestart: Bool { get }
}

/// Field is parsed by the engine from `mkxp.json` once at RGSS
/// thread startup. Mid-session edits land in the JSON but the
/// running engine keeps its launch-time copy until the next quit.
enum RestartFlag: SettingFlag {
    static let requiresRestart = true
}

/// Field flows through a host bridge or is pure host-side
/// rendering, so edits apply on resume without a relaunch.
enum RuntimeFlag: SettingFlag {
    static let requiresRestart = false
}


/// Type-erased view of a `@Setting`-wrapped property. Used by the
/// dirty-check to ask each property whether it requires a restart -
/// and whether its value differs from another instance's - without
/// knowing the property's value type at compile time.
private protocol AnySetting {
    var requiresRestart: Bool { get }
    func anyEquals(_ other: Any) -> Bool
}


/// Property wrapper carrying per-field metadata. The `Flag` generic
/// parameter is a phantom type that encodes the restart-required
/// nature of the field at compile time, so no per-instance state is
/// stored beyond the value itself and the JSON shape stays
/// identical to the un-wrapped form (single value per key, no
/// metadata serialized).
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


/// Allow a `GameSettings` JSON file to omit a wrapped optional
/// field entirely. Swift's auto-synthesized `init(from:)` only
/// applies the "missing key -> nil" rule to bare `Optional`
/// properties, not wrapper-typed ones, so without this overload
/// missing keys would throw "key not found" the first time a user
/// upgrades to a build that adds a new field.
extension KeyedDecodingContainer {
    func decode<V, F>(_ type: Setting<V?, F>.Type, forKey key: Key) throws -> Setting<V?, F>
    where V: Codable & Equatable, F: SettingFlag {
        if let value = try decodeIfPresent(type, forKey: key) {
            return value
        }
        return Setting(wrappedValue: nil)
    }
}


/// Per-game settings stored as `game_settings.json` in each game directory.
/// All fields are optional - nil means "use game/engine default".
///
/// Each field is annotated with `@Setting<..., RestartFlag>` or
/// `@Setting<..., RuntimeFlag>` so the dirty-check below can
/// surface a "restart required" hint in the UI when the user edits
/// a launch-time field while an engine session is active. When
/// adding a new field, pick the flag that matches how the value
/// reaches the engine (raw mkxp.json read at launch -> Restart;
/// host bridge or rendering -> Runtime).
struct GameSettings: Codable, Equatable {
    // Display
    /// true = bilinear (1), false = pixel-perfect (0)
    @Setting<Bool?, RestartFlag> var smoothScaling: Bool? = nil
    /// true = letterbox, false = stretch-to-fill
    @Setting<Bool?, RestartFlag> var fixedAspectRatio: Bool? = nil
    /// Render-buffer multiplier (1x / 2x / 4x). Maps to
    /// `enableHires` + `framebufferScalingFactor` in mkxp.json.
    /// Replaces the dead `resolution` field that wrote
    /// `defScreenW`/`defScreenH` (which only sized the SDL window
    /// and had no effect on iOS, since the window is always
    /// fullscreen).
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
    /// Nil = default (Ruby 1.8 compat for max PE fangame compatibility).
    /// True = disable syntaxTransform so the engine runs pure Ruby 3.
    /// Needed for games that ship Ruby-3-era scripts (keyword-arg
    /// hash shorthand, numbered block params, etc.) - notably Pokemon
    /// Reborn 19.5+, PE v20+, and any game packaged for the mkxp-z
    /// runtime. Detected automatically during JGP import by scanning
    /// .rb scripts for Ruby-3-only syntax, but users can also flip
    /// this manually per game if the heuristic misses.
    @Setting<Bool?, RestartFlag> var useModernRuby: Bool? = nil

    /// Force the Pokemon Essentials in-game keyboard scene for text
    /// entry instead of the iOS soft keyboard. Default false (use
    /// the soft keyboard, which works for IF / Reborn / Insurgence).
    /// Flip on for games whose keyboard scene adds custom keys or
    /// layouts that the iOS soft keyboard can't drive. Routes
    /// through the `mkxp_setUseInGameKeyboard` bridge to
    /// `pokemon_input.rb`'s `USEKEYBOARDTEXTENTRY = false` override.
    @Setting<Bool?, RuntimeFlag> var useInGameKeyboard: Bool? = nil


    private static let settingsFilename = "game_settings.json"
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

    /// True if any `RestartFlag`-tagged field differs between
    /// `self` and `other`. The engine reads its config once on RGSS
    /// thread startup and never re-reads, so launch-time fields
    /// need a full quit + relaunch to take effect; runtime fields
    /// (`RuntimeFlag`) flow through bridges and apply on resume.
    ///
    /// Walks the struct's properties via Mirror reflection - each
    /// `@Setting`-wrapped field exposes `requiresRestart` through
    /// the private `AnySetting` protocol, so this check stays
    /// accurate as new fields are added without any list to
    /// maintain. The author of a new field picks
    /// `@Setting<..., RestartFlag>` vs `RuntimeFlag` at the
    /// declaration site and the dirty-check follows automatically.
    func differsInRestartRequiredFields(from other: GameSettings) -> Bool {
        !restartRequiredFieldsChanged(from: other).isEmpty
    }


    /// User-facing labels of restart-required fields whose values
    /// differ between `self` and `other`. The UI feeds this into
    /// the restart-hint pill so the user sees which specific
    /// settings are pending a relaunch (e.g. "Smooth scaling and
    /// Render scale") instead of a generic "something changed".
    /// Order is the declaration order of the property wrappers,
    /// which keeps the rendered list visually stable as the user
    /// toggles fields back and forth.
    func restartRequiredFieldsChanged(from other: GameSettings) -> [String] {
        let lhsChildren = Mirror(reflecting: self).children
        let rhsChildren = Mirror(reflecting: other).children
        var changed: [String] = []
        for (lhs, rhs) in zip(lhsChildren, rhsChildren) {
            guard let lhsSetting = lhs.value as? AnySetting,
                  let rhsSetting = rhs.value as? AnySetting
            else {
                // Unwrapped properties bypass the dirty-check
                // silently in release builds; surface the omission
                // loudly in debug so the author of a new field gets
                // a clear nudge to add `@Setting<..., Flag>`.
                assertionFailure(
                    "GameSettings.\(lhs.label ?? "<unknown>") missing @Setting wrapper - "
                    + "the restart-hint logic can't see this field"
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


    /// Maps a Mirror property label (which the property-wrapper
    /// machinery renders with a leading underscore, e.g.
    /// `_smoothScaling`) to a user-facing label suitable for the
    /// restart-hint pill. Centralized switch instead of camelCase
    /// auto-formatting because the UI strings need real copy
    /// review (acronyms like "VSync", multi-word phrases, etc.)
    /// and silent string drift on rename would be worse than the
    /// modest maintenance cost of one entry per restart-required
    /// field.
    private static func displayLabel(forFieldLabel mirrorLabel: String) -> String {
        // The property-wrapper machinery prefixes Mirror labels
        // with an underscore. Normalize to the bare property name
        // so the switch reads naturally.
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
            // Fallback for fields added without an entry here -
            // surface the raw camelCase name so the bug is
            // visible in the UI rather than silently dropped.
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


    /// Scans a freshly-imported game folder for Ruby 3-only syntax
    /// markers and returns true if any are found. Used by the
    /// import pipeline to set `useModernRuby` so the engine runs
    /// without the Ruby 1.8 compat transform for games that ship
    /// modern Ruby source (Reborn 19.5+, PE v20+, mkxp-z JGPs).
    ///
    /// Detection runs three checks, in order, ANY-of:
    ///
    /// 1. Bundled Ruby 3.x runtime, detected by binary content
    ///    scan rather than filename. Modern custom engines ship
    ///    their own Ruby (Pokemon Flux's `x64-msvcrt-ruby310.dll`,
    ///    macOS bundles' `libruby.3.x.dylib`) because the original
    ///    RGSS player can't run their scripts. We open every
    ///    `.dll`/`.dylib`/`.so` in the game folder and look for
    ///    Ruby's embedded `RUBY_DESCRIPTION` byte pattern (e.g.,
    ///    `"ruby 3.1.4"`). This is robust against rename: a
    ///    developer can call the file `bundled.dll` and we still
    ///    detect it. Ruby 1.8/1.9 binaries embed `"ruby 1.8."` /
    ///    `"ruby 1.9."` instead, which the scan ignores; vanilla
    ///    RPG Maker XP/VX/Ace games therefore don't false-positive.
    ///    RGSS-version and Ruby-version are independent (RGSS1/2/3
    ///    is a graphics API choice, not a parser choice), so this
    ///    correctly handles RGSS1 games shipped with a modern Ruby.
    ///
    /// 2. `.fpk` packaging next to `Scripts.rxdata`. .fpk is a 7z
    ///    archive used by post-2020 custom engines (Pokemon Flux
    ///    ships scripts inside `Data/Data_0.fpk`, mounted at
    ///    runtime via `System.mount`). Vanilla RPG Maker doesn't
    ///    use .fpk; presence of one means a custom modern engine.
    ///    Complements signal 1 in case the bundled Ruby is
    ///    statically linked into a game .exe whose path we don't
    ///    walk.
    ///
    /// 3. Loose `.rb` files containing keyword-arg shorthand
    ///    (`id: -1,`, `foo: "bar",`). False positives on comments
    ///    or strings are possible but rare; disabling the transform
    ///    on a 1.8 game still runs it as Ruby 3, which works for
    ///    everything except legacy constructs the transform would
    ///    have rewritten (and the user can flip the setting back
    ///    manually).
    ///
    /// Signals 1 and 2 catch games that ship their entire script
    /// surface inside encrypted/packaged archives (Pokemon Flux,
    /// modern fan engines). Signal 3 catches games that ship loose
    /// .rb (Reborn 19+, Infinite Fusion, PE v20+).
    static func detectModernRubyScripts(in gameDirectory: URL) -> Bool {
        let fm = FileManager.default

        // Signal 1: scan native binaries for an embedded Ruby 3.x
        // version string. Robust to filename changes: the
        // `RUBY_DESCRIPTION` literal lives inside the binary at
        // a fixed offset relative to Ruby's `Init_*` machinery, so
        // searching for the byte pattern `"ruby 3."` in the file
        // contents is reliable even if the developer renames the
        // DLL/dylib.
        //
        // Capped at 64 MB per file as a safety bound. Real Ruby
        // DLLs are 5-15 MB; anything larger is unlikely to be
        // Ruby and not worth the IO cost.
        let binaryExtensions: Set<String> = ["dll", "dylib", "so"]
        let modernRubyMarker = Data("ruby 3.".utf8)
        let scanBudget = 64 * 1024 * 1024
        if let entries = try? fm.contentsOfDirectory(atPath: gameDirectory.path) {
            for entry in entries {
                let ext = (entry as NSString).pathExtension.lowercased()
                guard binaryExtensions.contains(ext) else { continue }
                let url = gameDirectory.appendingPathComponent(entry)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int,
                      size <= scanBudget,
                      let data = try? Data(contentsOf: url, options: .alwaysMapped)
                else { continue }
                if data.range(of: modernRubyMarker) != nil { return true }
            }
        }

        // Signal 2: .fpk packaging. The format is a 7z archive
        // containing scripts, mounted at runtime by the game's Main
        // bootstrapper via mkxp-z's `System.mount`. Only modern
        // custom engines use it, so its mere presence in `Data/`
        // is enough.
        let dataDir = gameDirectory.appendingPathComponent("Data")
        if let dataEntries = try? fm.contentsOfDirectory(atPath: dataDir.path) {
            for entry in dataEntries
            where entry.lowercased().hasSuffix(".fpk") {
                return true
            }
        }

        // Signal 3: loose .rb files with Ruby-3 keyword args.
        // Search depth is capped by the enumerator's defaults.
        // Stop at the first positive match to keep big fangames
        // from scanning thousands of files on import.
        let candidates = [
            gameDirectory,
            gameDirectory.appendingPathComponent("Scripts"),
            dataDir,
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


    /// Reads the game's mkxp.json defaults straight from the
    /// imported game folder. `gameDirectory` is the per-game
    /// `<container>/Game/` directory which is treated as immutable
    /// after import — Empo's managed config (`EmpoState/mkxp.json`)
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
            // The mkxp-z engine actually controls vsync via
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
    /// immutable after import — so reading the developer's source
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

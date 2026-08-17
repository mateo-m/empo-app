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
        case .x2: "Draw the game at 2x its normal size. Sharper on high-resolution screens."
        case .x4: "Draw the game at 4x its normal size. Sharpest, but harder on the battery."
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
// site. There is no separate descriptor list to keep in sync.

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
/// directory. All fields are optional. nil means "use game/engine
/// default".
///
/// Each field carries `@Setting<..., RestartFlag>` or
/// `@Setting<..., RuntimeFlag>`. The dirty-check below uses the flag
/// to surface a "restart required" hint when the user edits a
/// launch-time field during an active session. When adding a field,
/// pick the flag that matches how the value reaches the engine:
/// `mkxp.json` at launch -> Restart. Host bridge or rendering ->
/// Runtime.
struct GameSettings: Codable, Equatable {
    // Display
    /// portrait screen alignment. Host-side rendering, no engine input.
    @Setting<VerticalAlignment?, RuntimeFlag> var verticalAlignment: VerticalAlignment?

    // Performance
    /// fast-forward multiplier (2-9, nil = disabled). Runtime-only,
    /// applied via PlayerMoreSheet's Fast forward toggle through
    /// `mkxp_setFastForwardMultiplier`.
    @Setting<Int?, RuntimeFlag> var speedMultiplier: Int?

    // Engine
    /// execute postload scripts for common fixes
    @Setting<Bool?, RestartFlag> var postloadScripts: Bool?
    /// Override for the engine's syntax-transform mode. nil = auto
    /// (the script scanner picks based on the source's grammar).
    /// true = `MKXP_SYNTAX_TRANSFORM_DISABLED` (Ruby 3 strict, no
    /// rewrites). false = `MKXP_SYNTAX_TRANSFORM_LEGACY` (rewrite
    /// `when X:`, hash rockets, kwarg shorthand etc into Ruby-3
    /// compatible forms). Only the patched Ruby 3.1 parser applies
    /// the transforms. On the 1.8 / 1.9 / 3.0 builds the value is
    /// a no-op. Surfaced as the "Compatibility mode" picker in
    /// GameSettingsView.
    @Setting<Bool?, RestartFlag> var useModernRuby: Bool?

    /// Manual override for the per-game Ruby interpreter version.
    /// nil = use auto-detection from import. 18 / 19 / 30 / 31 forces
    /// that interpreter. Surfaced as the "Ruby version" picker in
    /// GameSettingsView and read by `AppState.selectGame` (calls
    /// `mkxp_setActiveRubyVersion()` before engine boot).
    ///
    /// Stored as Int so unknown values from a future Empo build don't
    /// break decoding. Restart-required because the active Ruby
    /// version is locked at app launch.
    @Setting<Int?, RestartFlag> var rubyVersionOverride: Int?

    /// Force the Pokemon Essentials in-game keyboard scene for text
    /// entry instead of the iOS soft keyboard. Default false (the
    /// soft keyboard works for IF / Reborn / Insurgence). Flip on
    /// for games whose keyboard scene adds custom keys the soft
    /// keyboard can't drive. Routes through `mkxp_setUseInGameKeyboard`
    /// to `pokemon_input.rb`'s `USEKEYBOARDTEXTENTRY = false` override.
    @Setting<Bool?, RuntimeFlag> var useInGameKeyboard: Bool?

    /// The game receives taps and drags on the game area as
    /// left-mouse input. This is harmless for games that never read
    /// the mouse (mouse state sits unread), so the default is ON.
    @Setting<Bool?, RuntimeFlag> var touchMouse: Bool?

    /// Make game scripts see `$joiplay = true` so they take their
    /// JoiPlay-specific code paths (mobile-friendly API calls, but
    /// also patches written against JoiPlay's old mkxp fork that can
    /// misbehave on our engine). Default off. Routes through
    /// `MKXPSessionConfig.joiplayCompat` to `platform_compat.rb`,
    /// which sets the global before game scripts load, so a
    /// restart is required.
    @Setting<Bool?, RestartFlag> var joiplayCompat: Bool?

    /// Let the game reach the network. On (the default), the engine's
    /// network stack works like desktop mkxp-z: `require 'net/http'`
    /// resolves against the bundled stdlib, HTTPLite streams real
    /// downloads, and game update systems function. Off simulates
    /// airplane mode: libraries still load, but every connection
    /// attempt fails the way it does with no connectivity, so games
    /// take their own offline fallback paths. Routes through
    /// `MKXPSessionConfig.networkEnabled`. The preload layer reads it
    /// via `System.network_enabled?` before game scripts load, so a
    /// restart is required.
    @Setting<Bool?, RestartFlag> var networkEnabled: Bool?

    private static let settingsFilename = "game_settings.json"

    /// Read the game's settings sidecar from `<container>/EmpoState/`
    /// (NOT the imported `Game/` subdir. Settings live outside the
    /// game files so the imported tree stays untouched).
    static func load(from stateDirectory: URL) -> GameSettings {
        let url = stateDirectory.appendingPathComponent(settingsFilename)
        guard let data = try? Data(contentsOf: url),
            let settings = try? JSONDecoder().decode(GameSettings.self, from: data)
        else {
            return GameSettings()
        }
        return settings
    }

    /// True when both Ruby-related controls are still on Auto, so
    /// Empo is free to refresh the persisted auto-detected Ruby
    /// version for this game on upgrade.
    var allowsRubyAutoDetectRefresh: Bool {
        rubyVersionOverride == nil && useModernRuby == nil
    }

    /// True if any `RestartFlag`-tagged field differs between `self`
    /// and `other`. The engine reads its config once at RGSS thread
    /// startup and never re-reads, so launch-time fields need a quit
    /// + relaunch. Runtime fields apply on resume.
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
                // Bare properties bypass the dirty-check in release.
                // Crash debug builds so a new field author remembers
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
        let key =
            mirrorLabel.hasPrefix("_")
            ? String(mirrorLabel.dropFirst())
            : mirrorLabel
        switch key {
        case "postloadScripts": return "Postload scripts"
        case "useModernRuby": return "Ruby compatibility mode"
        case "rubyVersionOverride": return "Ruby version"
        case "joiplayCompat": return "JoiPlay compatibility"
        case "networkEnabled": return "Network access"
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
    ///    strings are rare. Running a 1.8 game as Ruby 3 still works
    ///    for everything except legacy constructs the transform
    ///    would have rewritten, and the user can flip back manually.
    static func detectModernRubyScripts(in gameDirectory: URL) -> Bool {
        GameScriptProfile.analyze(gameDirectory: gameDirectory).modernRubyScripts
    }

    /// Resolve the engine's `syntaxTransform` mode for this game.
    /// Honors an explicit `useModernRuby` setting. Runs the .rb
    /// scanner when the setting is nil ("auto").
    ///
    /// Most PE fangames are written in Ruby 1.8 syntax and need
    /// the LEGACY transform so the engine rewrites old forms
    /// (`when X:`, unparenthesized method chains, legacy hash
    /// rockets, etc) before Ruby 3 parses them. Games that target
    /// the modern mkxp-z runtime (Reborn 19.5+, PE v20+, anything
    /// packaged as an mkxp-z JGP) ship actual Ruby 3 source
    /// (keyword-arg shorthand `id: -1`, `foo: "bar"`) which the
    /// 1.8 transform would mis-parse, so we DISABLE the transform
    /// for those.
    ///
    /// Auto-detect reads `metadata.modernRubyScriptsDetected`
    /// (refreshed at import, library load, launch, and Reset to
    /// Defaults when `useModernRuby` is nil). Falls back to an
    /// on-demand scan only when metadata has no cached value yet.
    func resolveSyntaxTransformMode(
        gameDirectory: URL,
        autoDetectedModern: Bool? = nil
    ) -> MKXPSyntaxTransformMode {
        let modern: Bool
        if let m = useModernRuby {
            modern = m
        } else if let detected = autoDetectedModern {
            modern = detected
        } else {
            modern = Self.detectModernRubyScripts(in: gameDirectory)
        }
        return modern
            ? MKXP_SYNTAX_TRANSFORM_DISABLED
            : MKXP_SYNTAX_TRANSFORM_LEGACY
    }

    /// Reads the game's mkxp.json defaults straight from the
    /// imported game folder. `gameDirectory` is the per-game
    /// `<container>/Game/` directory. Empo never writes this file.
    /// The sparse overlay at `EmpoState/mkxp.json` holds only
    /// Game Settings overrides.
    static func readGameDefaults(from gameDirectory: URL) -> GameConfigDefaults {
        EngineConfigProjector.readGameDefaults(from: gameDirectory)
    }

    /// One-time migration for installs that still carry engine keys in
    /// `game_settings.json`. Safe to call on every launch and settings
    /// open. No-ops once the keys are gone.
    static func migrateLegacyEngineSettingsIfNeeded(
        stateDirectory: URL,
        gameDirectory: URL
    ) {
        EngineConfigProjector.migrateLegacyEngineSettingsIfNeeded(
            stateDirectory: stateDirectory,
            gameDirectory: gameDirectory
        )
    }

    var hasCustomizations: Bool {
        self != GameSettings()
    }
}

/// Values from the game's mkxp.json. These are the developer's intended defaults.
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
    static let enginePathCache = true
    static let engineFontScale = 1.0
    static let engineSolidFonts = false
    static let enginePostloadScripts = true
    static let engineRenderScale = RenderScale.x1
    static let engineVerticalAlignment = VerticalAlignment.topCenter
}

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

    var bridgeValue: GameCoreVerticalAlignment {
        switch self {
        case .top: GAMECORE_VALIGN_TOP
        case .topCenter: GAMECORE_VALIGN_TOP_CENTER
        case .center: GAMECORE_VALIGN_CENTER
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
/// launch-time copy until the app closes and opens again.
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

/// Lets a settings JSON file omit a wrapped optional field. Swift's
/// synthesized `init(from:)` treats a missing key as nil only for a
/// bare `Optional` property, not for a wrapped one, so a new field
/// would throw "key not found" on the first upgrade without this.
extension KeyedDecodingContainer {
    func decode<V, F>(_ type: Setting<V?, F>.Type, forKey key: Key) throws -> Setting<V?, F>
    where V: Codable & Equatable, F: SettingFlag {
        if let value = try decodeIfPresent(type, forKey: key) {
            return value
        }
        return Setting(wrappedValue: nil)
    }
}

/// A group of per-game settings stored as keys of
/// `EmpoState/game_settings.json`. The app and the core of the game
/// each own one group, so each save writes only its own keys.
///
/// Each field carries `@Setting<..., RestartFlag>` or
/// `@Setting<..., RuntimeFlag>`. The settings sheet uses the flag to
/// show a "restart required" hint when the user edits a launch-time
/// field during an active session.
protocol GameSettingsGroup: Codable, Equatable {
    init()
    /// The name of a restart-required field in the restart hint.
    static func displayLabel(forKey key: String) -> String
}

extension GameSettingsGroup {
    static func load(from stateDirectory: URL) -> Self {
        let url = stateDirectory.appendingPathComponent(gameSettingsFilename)
        guard let data = try? Data(contentsOf: url),
            let settings = try? JSONDecoder().decode(Self.self, from: data)
        else {
            return Self()
        }
        return settings
    }

    func save(to stateDirectory: URL) {
        // The settings sheet can open before anything created
        // `EmpoState/`. An atomic write into a missing directory
        // fails silently, so create it first.
        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true
        )
        let url = stateDirectory.appendingPathComponent(gameSettingsFilename)
        guard let encoded = try? JSONEncoder().encode(self),
            let mine = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { return }
        var all =
            (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        all.merge(mine) { $1 }
        if let data = try? JSONSerialization.data(
            withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
        {
            try? data.write(to: url, options: .atomic)
        }
    }

    var hasCustomizations: Bool {
        self != Self()
    }

    /// The labels of the restart-required fields that differ between
    /// `self` and `other`, in declaration order.
    func restartRequiredFieldsChanged(from other: Self) -> [String] {
        var changed: [String] = []
        for (lhs, rhs) in zip(Mirror(reflecting: self).children, Mirror(reflecting: other).children) {
            guard let lhsSetting = lhs.value as? AnySetting,
                let rhsSetting = rhs.value as? AnySetting
            else {
                assertionFailure(
                    "\(Self.self).\(lhs.label ?? "<unknown>") missing @Setting wrapper - "
                        + "restart-hint logic can't see this field"
                )
                continue
            }
            guard lhsSetting.requiresRestart,
                !lhsSetting.anyEquals(rhsSetting),
                let label = lhs.label
            else { continue }
            changed.append(Self.displayLabel(forKey: settingKey(label)))
        }
        return changed
    }
}

private let gameSettingsFilename = "game_settings.json"

/// Strips the leading underscore that the property-wrapper machinery
/// puts on Mirror labels, so `_touchMouse` reads back as the declared
/// name.
private func settingKey(_ mirrorLabel: String) -> String {
    mirrorLabel.hasPrefix("_") ? String(mirrorLabel.dropFirst()) : mirrorLabel
}

/// The per-game settings that every core shares.
struct GameSettings: GameSettingsGroup {
    /// Where the game sits on a portrait screen before a layout
    /// profile places it. The sheet has no picker for this. Screen
    /// position belongs to the layout editor now, and a pinned
    /// profile region beats the alignment in `recalculateScreenSize`.
    /// Nothing in the app writes this field. Only a settings file
    /// from before the layout editor holds a value, and the engine
    /// reads it at launch.
    @Setting<VerticalAlignment?, RestartFlag> var verticalAlignment: VerticalAlignment?

    /// fast-forward multiplier (2-9, nil = disabled). Runtime-only,
    /// applied via PlayerMoreSheet's Fast forward toggle through
    /// `gamecore_setFastForwardMultiplier`.
    @Setting<Int?, RuntimeFlag> var speedMultiplier: Int?

    /// The game receives taps and drags on the game area as
    /// left-mouse input. This is harmless for games that never read
    /// the mouse (mouse state sits unread), so the default is ON.
    @Setting<Bool?, RuntimeFlag> var touchMouse: Bool?

    /// `RuntimeFlag` fields that something re-pushes to the engine
    /// while a game runs. `PlayerRuntimeState.reconcile` owns those
    /// pushes and calls the check below to keep this list honest.
    private static let runtimeAppliedFields: Set<String> = [
        "speedMultiplier",
        "touchMouse",
    ]

    /// Crashes debug builds when a `RuntimeFlag` field has no
    /// applier. The flag promises the settings sheet that an edit
    /// applies on resume, and the sheet hides its restart hint on the
    /// strength of that promise. A field nobody re-pushes reaches the
    /// engine at launch only, so the control looks live and does
    /// nothing. That was the `touchMouse` bug.
    static func assertRuntimeFieldsHaveAppliers() {
        #if DEBUG
        for child in Mirror(reflecting: GameSettings()).children {
            guard let label = child.label,
                let setting = child.value as? AnySetting,
                !setting.requiresRestart
            else { continue }
            let key = settingKey(label)
            guard !runtimeAppliedFields.contains(key) else { continue }
            assertionFailure(
                "GameSettings.\(key) is RuntimeFlag but nothing re-applies it "
                    + "mid-session - add the push to PlayerRuntimeState.reconcile "
                    + "and name the field in runtimeAppliedFields"
            )
        }
        #endif
    }

    static func displayLabel(forKey key: String) -> String {
        switch key {
        case "verticalAlignment": return "Screen position"
        default:
            assertionFailure("Missing displayLabel mapping for GameSettings.\(key)")
            return key
        }
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

    /// The value the engine bridge takes for `touchMouse`. Both the
    /// launch push and `PlayerRuntimeState.reconcile` read this, so
    /// the default lives in one place.
    var touchMouseEnabled: Bool {
        touchMouse ?? GameConfigDefaults.engineTouchMouse
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
    static let engineRenderScale = RenderScale.x1
    static let engineVerticalAlignment = VerticalAlignment.topCenter
    static let engineTouchMouse = true
}

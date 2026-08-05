import Foundation

/// Per-game layout-profile pin, stored in
/// `EmpoState/layout_profile.json`. A dedicated file: older app
/// versions rewrite `game_settings.json` and would strip unknown
/// keys.
public enum LayoutPin: Equatable, Sendable {
    /// File absent, `pin` key absent, or unreadable: resolve the
    /// chain (game layout, then default profile, then builtin).
    case followChain
    /// Pinned to a named profile.
    case profile(String)
    /// Force the game-shipped layout (`"$game"`).
    case gameLayout
    /// Always follow the current default profile (`"$default"`).
    case defaultProfile
}

public enum LayoutPinFile {
    public static let fileName = "layout_profile.json"

    static let gameSentinel = "$game"
    static let defaultSentinel = "$default"

    /// Absent file = follow the chain. An unreadable file or an
    /// unknown version also resolves as follow-the-chain, with a
    /// note for the log.
    public static func load(from url: URL) -> (pin: LayoutPin, note: String?) {
        guard let data = try? Data(contentsOf: url) else {
            return (.followChain, nil)
        }
        return parse(data: data)
    }

    public static func parse(data: Data) -> (pin: LayoutPin, note: String?) {
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let version = object["version"] as? Int
        else {
            return (.followChain, "layout_profile.json: unreadable, following the chain")
        }
        guard version == 1 else {
            return (.followChain, "layout_profile.json: unknown version \(version), following the chain")
        }
        guard let raw = object["pin"] as? String else {
            return (.followChain, nil)
        }
        switch raw {
        case gameSentinel:
            return (.gameLayout, nil)
        case defaultSentinel:
            return (.defaultProfile, nil)
        default:
            if raw.hasPrefix("$") {
                return (.followChain, "layout_profile.json: unknown pin \(raw), following the chain")
            }
            return (.profile(raw.precomposedStringWithCanonicalMapping), nil)
        }
    }

    /// `followChain` still writes `{"version":1}`: an explicit
    /// "Automatic" choice must be distinguishable from a game the
    /// migration has never seen (which has no file).
    public static func serialize(_ pin: LayoutPin) -> Data {
        var object: [String: Any] = ["version": 1]
        switch pin {
        case .followChain:
            break
        case .profile(let name):
            object["pin"] = name
        case .gameLayout:
            object["pin"] = gameSentinel
        case .defaultProfile:
            object["pin"] = defaultSentinel
        }
        let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        return data ?? Data("{\"version\":1}".utf8)
    }
}

/// Which chain level won, for banners and pickers.
public enum LayoutProvenance: Equatable, Sendable {
    case pinnedProfile(String)
    case gameLayout
    case defaultProfile(String)
    case builtin
}

/// Pure chain resolution over per-level occupancy flags. Payload
/// fetch stays with the caller, and the game-layout level is an
/// optional slot, so the same resolver serves `controls.json` now
/// and `screen.json` later (which has no game level).
public enum LayoutChainResolver {
    public struct Levels: Sendable {
        /// nil when the pin names no profile; else whether that
        /// profile's section exists and is valid.
        public var pinnedProfileValid: Bool?
        /// Whether the game ships a usable layout at this level.
        public var gameLayoutOccupied: Bool
        /// nil when no default profile is set; else whether its
        /// section exists and is valid.
        public var defaultProfileValid: Bool?

        public init(
            pinnedProfileValid: Bool?,
            gameLayoutOccupied: Bool,
            defaultProfileValid: Bool?
        ) {
            self.pinnedProfileValid = pinnedProfileValid
            self.gameLayoutOccupied = gameLayoutOccupied
            self.defaultProfileValid = defaultProfileValid
        }
    }

    public enum Level: Equatable, Sendable {
        case pinnedProfile
        case gameLayout
        case defaultProfile
        case builtin
    }

    public struct Outcome: Equatable, Sendable {
        public var level: Level
        /// Set when the pinned target was missing or invalid and the
        /// resolution fell through. The caller surfaces it once.
        public var fellThrough: Bool

        public init(level: Level, fellThrough: Bool) {
            self.level = level
            self.fellThrough = fellThrough
        }
    }

    public static func resolve(pin: LayoutPin, levels: Levels) -> Outcome {
        switch pin {
        case .profile:
            if levels.pinnedProfileValid == true {
                return Outcome(level: .pinnedProfile, fellThrough: false)
            }
            // Missing or invalid named pin: resume the chain at the
            // game level.
            return Outcome(
                level: chainTail(levels), fellThrough: true)
        case .gameLayout:
            if levels.gameLayoutOccupied {
                return Outcome(level: .gameLayout, fellThrough: false)
            }
            // The $game pin exists to escape the default profile, so
            // its fallback skips level 3 on purpose.
            return Outcome(level: .builtin, fellThrough: true)
        case .defaultProfile:
            if levels.defaultProfileValid == true {
                return Outcome(level: .defaultProfile, fellThrough: false)
            }
            return Outcome(level: .builtin, fellThrough: true)
        case .followChain:
            return Outcome(level: chainTail(levels), fellThrough: false)
        }
    }

    private static func chainTail(_ levels: Levels) -> Level {
        if levels.gameLayoutOccupied { return .gameLayout }
        if levels.defaultProfileValid == true { return .defaultProfile }
        return .builtin
    }
}

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

/// Pure chain resolution over per-level occupancy. Payload fetch
/// stays with the caller, and the game-layout level is an optional
/// slot, so the same resolver serves `controls.json` now and
/// `screen.json` later (which has no game level). The levels carry
/// their profile NAMES, so the outcome is a full `LayoutProvenance`
/// and no caller re-joins names to levels.
public enum LayoutChainResolver {
    public struct Levels: Sendable {
        /// nil when the pin names no profile; else the pinned name
        /// plus whether that profile's section exists and is valid.
        public var pinnedProfile: (name: String, valid: Bool)?
        /// Whether the game ships a usable layout at this level.
        public var gameLayoutOccupied: Bool
        /// nil when no default profile is set.
        public var defaultProfile: (name: String, valid: Bool)?

        public init(
            pinnedProfile: (name: String, valid: Bool)?,
            gameLayoutOccupied: Bool,
            defaultProfile: (name: String, valid: Bool)?
        ) {
            self.pinnedProfile = pinnedProfile
            self.gameLayoutOccupied = gameLayoutOccupied
            self.defaultProfile = defaultProfile
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var provenance: LayoutProvenance
        /// Set when the pinned target was missing or invalid and the
        /// resolution fell through. The caller surfaces it once.
        public var fellThrough: Bool

        public init(provenance: LayoutProvenance, fellThrough: Bool) {
            self.provenance = provenance
            self.fellThrough = fellThrough
        }
    }

    public static func resolve(pin: LayoutPin, levels: Levels) -> Outcome {
        switch pin {
        case .profile:
            if let pinned = levels.pinnedProfile, pinned.valid {
                return Outcome(
                    provenance: .pinnedProfile(pinned.name), fellThrough: false)
            }
            // Missing or invalid named pin: resume the chain at the
            // game level.
            return Outcome(provenance: chainTail(levels), fellThrough: true)
        case .gameLayout:
            if levels.gameLayoutOccupied {
                return Outcome(provenance: .gameLayout, fellThrough: false)
            }
            // The $game pin exists to escape the default profile, so
            // its fallback skips level 3 on purpose.
            return Outcome(provenance: .builtin, fellThrough: true)
        case .defaultProfile:
            if let defaultProfile = levels.defaultProfile, defaultProfile.valid {
                return Outcome(
                    provenance: .defaultProfile(defaultProfile.name), fellThrough: false)
            }
            return Outcome(provenance: .builtin, fellThrough: true)
        case .followChain:
            return Outcome(provenance: chainTail(levels), fellThrough: false)
        }
    }

    private static func chainTail(_ levels: Levels) -> LayoutProvenance {
        if levels.gameLayoutOccupied { return .gameLayout }
        if let defaultProfile = levels.defaultProfile, defaultProfile.valid {
            return .defaultProfile(defaultProfile.name)
        }
        return .builtin
    }
}

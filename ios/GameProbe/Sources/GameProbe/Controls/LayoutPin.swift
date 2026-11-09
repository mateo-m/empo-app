// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// The pin has its own file, `EmpoState/layout_profile.json`. Older app
/// versions rewrite `game_settings.json` and strip unknown keys.
public enum LayoutPin: Equatable, Sendable {
    case followChain
    case profile(String)
    case gameLayout
    case defaultProfile
}

public enum LayoutPinFile {
    public static let fileName = "layout_profile.json"

    /// A pin that starts with it names no profile, so no profile name
    /// may start with it.
    static let sentinelPrefix = "$"
    static let gameSentinel = sentinelPrefix + "game"
    static let defaultSentinel = sentinelPrefix + "default"

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
            if raw.hasPrefix(sentinelPrefix) {
                return (.followChain, "layout_profile.json: unknown pin \(raw), following the chain")
            }
            // The pin file sits in the game folder, so users can
            // hand-edit it. An unvalidated name would flow into
            // profile path building. ".." must never do that.
            let name = raw.precomposedStringWithCanonicalMapping
            guard LayoutProfileStore.validatedName(name) == name else {
                return (.followChain, "layout_profile.json: invalid pin \(raw), following the chain")
            }
            return (.profile(name), nil)
        }
    }

    /// `followChain` still writes `{"version":1}`: an explicit
    /// "Automatic" choice must be distinguishable from a game the
    /// migration has never seen (which has no file).
    public static func serialize(_ pin: LayoutPin) throws -> Data {
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
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

public enum LayoutProvenance: Equatable, Sendable {
    case pinnedProfile(String)
    case gameLayout
    case defaultProfile(String)
    case builtin
}

public enum LayoutChainResolver {
    public struct Levels: Sendable {
        public var pinnedProfile: (name: String, valid: Bool)?
        public var gameLayoutOccupied: Bool
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

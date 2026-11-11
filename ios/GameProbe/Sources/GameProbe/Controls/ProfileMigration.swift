// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// FNV-1a 64 for migration dedupe lookups. Not cryptographic. The
/// caller compares canonical bytes before acting on a match.
public enum FNV1a {
    public static func hash64(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

/// Profiles never store sparse sections. A sparse section resolves
/// against whatever game it is pinned to, which breaks portability.
public enum ProfileMaterializer {
    public struct Builtins: Sendable {
        public var portrait: TouchLayout
        public var landscape: TouchLayout

        /// `keys` are the keys of the game core, in grid order.
        public init(keys: [BuiltinLayout.Key]) {
            portrait = BuiltinLayout.layout(keys: keys, isLandscape: false)
            landscape = BuiltinLayout.layout(keys: keys, isLandscape: true)
        }
    }

    public struct MaterializedTouch: Equatable, Sendable {
        public var portrait: TouchLayout
        public var landscape: TouchLayout

        public var section: TouchSection {
            TouchSection(portrait: portrait, landscape: landscape)
        }
    }

    /// To complete a profile section, pass `manifest: nil`. Profile gaps
    /// fill from the builtin only, never from a game manifest.
    public static func materialize(
        user: TouchSection?,
        manifest: TouchSection?,
        builtins: Builtins,
        metrics: TouchZoneMetrics
    ) -> MaterializedTouch {
        let completedManifest = manifest.map {
            TouchSectionCompletion.complete($0, metrics: metrics).section
        }
        let completedUser = user.map {
            TouchSectionCompletion.complete($0, metrics: metrics).section
        }

        return MaterializedTouch(
            portrait: materializeOrientation(
                user: completedUser?.portrait,
                manifest: completedManifest?.portrait,
                builtin: builtins.portrait
            ),
            landscape: materializeOrientation(
                user: completedUser?.landscape,
                manifest: completedManifest?.landscape,
                builtin: builtins.landscape
            )
        )
    }

    public static func canonicalBytes(_ materialized: MaterializedTouch) -> Data {
        ControlsManifestSerializer.serialize(materialized.section)
    }

    private static func materializeOrientation(
        user: TouchLayout?,
        manifest: TouchLayout?,
        builtin: TouchLayout
    ) -> TouchLayout {
        TouchLayout(
            dpad: user?.dpad ?? manifest?.dpad ?? builtin.dpad,
            buttons: user?.buttons ?? manifest?.buttons ?? builtin.buttons ?? [],
            actionButtons: user?.actionButtons ?? manifest?.actionButtons
                ?? builtin.actionButtons ?? []
        )
    }
}

/// `Documents/Profiles/.migration.json`, which games have been
/// migrated, with the canonical hash of what was migrated and the
/// profile it went into.
public struct MigrationRecord: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var hash: String
        public var profile: String?

        public init(hash: String, profile: String?) {
            self.hash = hash
            self.profile = profile
        }
    }

    public var games: [String: Entry]
    /// Profiles that two games came to use. One game can later leave
    /// the profile, so the count of games can't tell this.
    public var sharedProfiles: Set<String>

    public init(games: [String: Entry] = [:], sharedProfiles: Set<String> = []) {
        self.games = games
        self.sharedProfiles = sharedProfiles
    }

    public static let fileName = ".migration.json"

    /// A missing file reads as an empty record. nil when the file is
    /// there but cannot be read, so that the caller does not migrate
    /// every game again.
    public static func load(at url: URL) -> MigrationRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return MigrationRecord() }
        return (try? Data(contentsOf: url)).flatMap(parse(data:))
    }

    public func save(to url: URL) throws {
        try serialize().write(to: url, options: .atomic)
    }

    public static func parse(data: Data) -> MigrationRecord? {
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            object["version"] as? Int == 1,
            let rawGames = object["games"] as? [String: [String: Any]]
        else { return nil }
        var games: [String: Entry] = [:]
        for (id, raw) in rawGames {
            guard let hash = raw["hash"] as? String else { continue }
            games[id] = Entry(hash: hash, profile: raw["profile"] as? String)
        }
        // Versions without the list named every shared profile
        // "Shared layout", "Shared layout 2", and so on, in English.
        let shared =
            (object["shared"] as? [String]).map(Set.init)
            ?? Set(games.values.compactMap(\.profile).filter { $0.hasPrefix("Shared layout") })
        return MigrationRecord(games: games, sharedProfiles: shared)
    }

    public mutating func renameProfile(from oldName: String, to newName: String) {
        for (gameID, entry) in games where entry.profile == oldName {
            games[gameID]?.profile = newName
        }
        if sharedProfiles.remove(oldName) != nil {
            sharedProfiles.insert(newName)
        }
    }

    public func serialize() throws -> Data {
        var rawGames: [String: [String: Any]] = [:]
        for (id, entry) in games {
            var raw: [String: Any] = ["hash": entry.hash]
            if let profile = entry.profile {
                raw["profile"] = profile
            }
            rawGames[id] = raw
        }
        let object: [String: Any] = [
            "version": 1, "games": rawGames, "shared": sharedProfiles.sorted(),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

public enum ProfileMigration {
    public enum Action: Equatable, Sendable {
        case none
        case recordOnly(hash: String)
        /// The section changed after migration: offer the import,
        /// never auto-migrate again.
        case importOffer
        case createAndPin(baseName: String, hash: String)
        case pinToExisting(profile: String, renameToShared: Bool, hash: String)
    }

    public struct Context {
        public var gameID: String
        public var gameTitle: String
        public var userTouch: TouchSection?
        public var manifestTouch: TouchSection?
        public var pinFileExists: Bool
        public var record: MigrationRecord
        public var existingProfiles: [String]
        /// Canonical bytes per profile, or nil when unreadable.
        public var profileCanonicalBytes: (String) -> Data?
        /// Screen-bearing profiles never dedupe-match: a migrated
        /// game's layout has no screen data, so pinning to one would
        /// silently move the game's screen.
        public var profileHasScreen: (String) -> Bool

        public init(
            gameID: String,
            gameTitle: String,
            userTouch: TouchSection?,
            manifestTouch: TouchSection?,
            pinFileExists: Bool,
            record: MigrationRecord,
            existingProfiles: [String],
            profileCanonicalBytes: @escaping (String) -> Data?,
            profileHasScreen: @escaping (String) -> Bool
        ) {
            self.gameID = gameID
            self.gameTitle = gameTitle
            self.userTouch = userTouch
            self.manifestTouch = manifestTouch
            self.pinFileExists = pinFileExists
            self.record = record
            self.existingProfiles = existingProfiles
            self.profileCanonicalBytes = profileCanonicalBytes
            self.profileHasScreen = profileHasScreen
        }
    }

    public static func decide(
        context: Context,
        builtins: ProfileMaterializer.Builtins,
        metrics: TouchZoneMetrics
    ) -> Action {
        guard let userTouch = context.userTouch else {
            // Section absent. A stale record entry stays: it only
            // means "this content was migrated once".
            return .none
        }

        let materialized = ProfileMaterializer.materialize(
            user: userTouch, manifest: context.manifestTouch,
            builtins: builtins, metrics: metrics)
        let canonical = ProfileMaterializer.canonicalBytes(materialized)
        let hash = FNV1a.hash64(canonical)

        if let entry = context.record.games[context.gameID] {
            return entry.hash == hash ? .none : .importOffer
        }

        // A layout equal to the ambient default carries no user
        // intent: record it so this check never re-runs, create
        // nothing.
        let ambient = ProfileMaterializer.materialize(
            user: nil, manifest: context.manifestTouch,
            builtins: builtins, metrics: metrics)
        if ProfileMaterializer.canonicalBytes(ambient) == canonical {
            return .recordOnly(hash: hash)
        }

        // The user already chose a pin post-profiles: never override
        // it, and do not mint an orphan profile.
        if context.pinFileExists {
            return .recordOnly(hash: hash)
        }

        // Dedupe: hash is only a shortcut. Bytes decide. Profiles
        // with a screen region are skipped. Equal controls bytes do
        // not make them true duplicates of screen-less game content.
        let migrationProfiles = Set(context.record.games.values.compactMap(\.profile))
        for profile in context.existingProfiles {
            guard !context.profileHasScreen(profile) else { continue }
            guard let bytes = context.profileCanonicalBytes(profile), bytes == canonical else {
                continue
            }
            let renameToShared =
                migrationProfiles.contains(profile) && !context.record.sharedProfiles.contains(profile)
            return .pinToExisting(profile: profile, renameToShared: renameToShared, hash: hash)
        }

        return .createAndPin(baseName: context.gameTitle, hash: hash)
    }
}

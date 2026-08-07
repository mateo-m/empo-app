import Foundation

/// FNV-1a 64 for migration dedupe lookups. Not cryptographic; the
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

/// Builds the fully materialized form of a game's touch layout:
/// both orientations, and inside each `dpad`, `buttons`, and
/// `actionButtons` all present. Profiles never store sparse
/// sections — a sparse section resolves against whatever game it is
/// pinned to, which breaks portability.
public enum ProfileMaterializer {
    /// Concrete builtin defaults, injected by the app (GameProbe has
    /// no scancode table for the default buttons).
    public struct Builtins: Sendable {
        public var portrait: TouchLayout
        public var landscape: TouchLayout

        public init(portrait: TouchLayout, landscape: TouchLayout) {
            self.portrait = portrait
            self.landscape = landscape
        }

        var defaultDpad: TouchSectionCompletion.DefaultDpadSpec {
            TouchSectionCompletion.DefaultDpadSpec(
                portraitX: portrait.dpad?.x ?? 0.13,
                portraitY: portrait.dpad?.y ?? 0.72,
                landscapeX: landscape.dpad?.x ?? 0.10,
                landscapeY: landscape.dpad?.y ?? 0.65,
                size: portrait.dpad?.size ?? 140
            )
        }
    }

    /// Materialization is total: both orientations are ALWAYS
    /// present, and the type says so — no caller carries a dead
    /// empty-layout fallback for a nil that cannot happen.
    public struct MaterializedTouch: Equatable, Sendable {
        public var portrait: TouchLayout
        public var landscape: TouchLayout

        /// The sparse-capable spec shape, for serialization.
        public var section: TouchSection {
            TouchSection(portrait: portrait, landscape: landscape)
        }
    }

    /// `user` layers over `manifest` layers over `builtins`, per
    /// orientation and per field. Pass `manifest: nil` to complete a
    /// PROFILE section: profile gaps fill from the builtin only,
    /// never from a game manifest.
    public static func materialize(
        user: TouchSection?,
        manifest: TouchSection?,
        builtins: Builtins,
        metrics: TouchZoneMetrics
    ) -> MaterializedTouch {
        let completedManifest = manifest.map {
            TouchSectionCompletion.complete(
                $0, metrics: metrics, defaultDpad: builtins.defaultDpad
            ).section
        }
        let completedUser = user.map {
            TouchSectionCompletion.complete(
                $0, metrics: metrics, defaultDpad: builtins.defaultDpad
            ).section
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

    /// The serializer has no touch-only entry point; canonical bytes
    /// are always `serialize(touch:controller: nil)`.
    public static func canonicalBytes(_ section: TouchSection) -> Data {
        ControlsManifestSerializer.serialize(touch: section, controller: nil) ?? Data()
    }

    public static func canonicalBytes(_ materialized: MaterializedTouch) -> Data {
        canonicalBytes(materialized.section)
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

/// `Documents/Profiles/.migration.json` — which games have been
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

    public init(games: [String: Entry] = [:]) {
        self.games = games
    }

    public static let fileName = ".migration.json"

    /// Missing or unreadable file reads as an empty record, the
    /// same rule both app call sites hand-rolled before.
    public static func load(at url: URL) -> MigrationRecord {
        (try? Data(contentsOf: url)).map(parse) ?? MigrationRecord()
    }

    public func save(to url: URL) {
        try? serialize().write(to: url, options: .atomic)
    }

    public static func parse(data: Data) -> MigrationRecord {
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            object["version"] as? Int == 1,
            let rawGames = object["games"] as? [String: [String: Any]]
        else { return MigrationRecord() }
        var games: [String: Entry] = [:]
        for (id, raw) in rawGames {
            guard let hash = raw["hash"] as? String else { continue }
            games[id] = Entry(hash: hash, profile: raw["profile"] as? String)
        }
        return MigrationRecord(games: games)
    }

    public func serialize() -> Data {
        var rawGames: [String: [String: Any]] = [:]
        for (id, entry) in games {
            var raw: [String: Any] = ["hash": entry.hash]
            if let profile = entry.profile {
                raw["profile"] = profile
            }
            rawGames[id] = raw
        }
        let object: [String: Any] = ["version": 1, "games": rawGames]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data()
    }
}

/// Pure migration decision for one game. The app orchestrates the
/// store writes the action describes.
public enum ProfileMigration {
    public enum Action: Equatable, Sendable {
        /// Nothing to do (no section, or already migrated unchanged).
        case none
        /// Record the hash but create nothing: the layout equals the
        /// ambient default, or the user already has a pin file.
        case recordOnly(hash: String)
        /// The section changed after migration: offer the import,
        /// never auto-migrate again.
        case importOffer
        /// Create a profile from the materialized section, pin the
        /// game to it, record.
        case createAndPin(baseName: String, hash: String)
        /// The content matches an existing profile: pin to it. When
        /// the match is another game's migration profile, rename it
        /// to the shared name (through the store's pin-walk rename).
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
        /// Canonical bytes per profile; nil when unreadable.
        public var profileCanonicalBytes: (String) -> Data?

        public init(
            gameID: String,
            gameTitle: String,
            userTouch: TouchSection?,
            manifestTouch: TouchSection?,
            pinFileExists: Bool,
            record: MigrationRecord,
            existingProfiles: [String],
            profileCanonicalBytes: @escaping (String) -> Data?
        ) {
            self.gameID = gameID
            self.gameTitle = gameTitle
            self.userTouch = userTouch
            self.manifestTouch = manifestTouch
            self.pinFileExists = pinFileExists
            self.record = record
            self.existingProfiles = existingProfiles
            self.profileCanonicalBytes = profileCanonicalBytes
        }
    }

    public static func decide(
        context: Context,
        builtins: ProfileMaterializer.Builtins,
        metrics: TouchZoneMetrics = .reference
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

        // Dedupe: hash is only a shortcut; bytes decide.
        let migrationProfiles = Set(context.record.games.values.compactMap(\.profile))
        for profile in context.existingProfiles {
            guard let bytes = context.profileCanonicalBytes(profile), bytes == canonical else {
                continue
            }
            let renameToShared =
                migrationProfiles.contains(profile) && !profile.hasPrefix("Shared layout")
            return .pinToExisting(profile: profile, renameToShared: renameToShared, hash: hash)
        }

        return .createAndPin(baseName: context.gameTitle, hash: hash)
    }
}

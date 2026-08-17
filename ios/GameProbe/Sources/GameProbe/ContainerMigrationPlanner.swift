import Foundation

/// Pure planning for the legacy `<uuid>-<slug>` container migration:
/// which copy of each title keeps the canonical name, and which are
/// duplicates. The app-side executor performs the actual renames.
///
/// The library invariant is one container per title (games locate
/// their data by their INI title), so within a title group exactly
/// one candidate may claim the canonical name: the one played most
/// recently, then the one added most recently, then - for full
/// determinism - the lexicographically first id.
public enum ContainerMigrationPlanner {

    public struct Candidate: Equatable, Sendable {
        /// Unique key for the candidate: its legacy folder name.
        public let id: String
        /// Sanitized destination title (`GameFolderName.sanitize`).
        public let preferredName: String
        public let lastPlayed: Date?
        public let dateAdded: Date?

        public init(
            id: String,
            preferredName: String,
            lastPlayed: Date?,
            dateAdded: Date?
        ) {
            self.id = id
            self.preferredName = preferredName
            self.lastPlayed = lastPlayed
            self.dateAdded = dateAdded
        }
    }

    public struct TitleGroup: Equatable, Sendable {
        /// Candidates in canonical-first order. The executor renames
        /// the first that succeeds and quarantines the rest.
        public let candidates: [Candidate]
        /// True when a post-migration container already owns the
        /// title (an interrupted earlier run): every candidate is
        /// then a duplicate.
        public let titleAlreadyTaken: Bool

        public init(candidates: [Candidate], titleAlreadyTaken: Bool) {
            self.candidates = candidates
            self.titleAlreadyTaken = titleAlreadyTaken
        }
    }

    /// Group `candidates` by destination title (case-insensitively,
    /// so two titles differing only in case can't produce colliding
    /// directories) and order each group canonical-first. Groups
    /// come back sorted by title key so the plan is deterministic.
    public static func plan(
        candidates: [Candidate],
        takenLowercasedNames: Set<String>
    ) -> [TitleGroup] {
        let groups = Dictionary(grouping: candidates) { $0.preferredName.lowercased() }
        return groups.keys.sorted().map { key in
            let ordered = groups[key, default: []].sorted { lhs, rhs in
                let lhsPlayed = lhs.lastPlayed ?? .distantPast
                let rhsPlayed = rhs.lastPlayed ?? .distantPast
                if lhsPlayed != rhsPlayed { return lhsPlayed > rhsPlayed }
                let lhsAdded = lhs.dateAdded ?? .distantPast
                let rhsAdded = rhs.dateAdded ?? .distantPast
                if lhsAdded != rhsAdded { return lhsAdded > rhsAdded }
                return lhs.id < rhs.id
            }
            return TitleGroup(
                candidates: ordered,
                titleAlreadyTaken: takenLowercasedNames.contains(key)
            )
        }
    }

    /// The `<uuid>` prefix of a pre-v0.5 legacy folder name (the
    /// old container id), or nil for post-migration title-based
    /// names. The legacy importer wrote `<uuid>-<slug>`, or a bare
    /// `<uuid>` when the slug was empty - so a valid prefix is
    /// exactly one of those two shapes. Anything longer without
    /// the `-` separator is a title that merely STARTS with a
    /// UUID. Matching it would classify the migrated name as
    /// legacy on every launch and retry a self-rename forever.
    public static func legacyUUIDPrefix(folderName: String) -> String? {
        guard folderName.count >= 36 else { return nil }
        let uuidPart = String(folderName.prefix(36))
        guard UUID(uuidString: uuidPart) != nil else { return nil }
        guard folderName.count == 36 || folderName.dropFirst(36).first == "-" else {
            return nil
        }
        return uuidPart
    }

    /// The corrected folder name for a container named in the
    /// mojibake era, when `decodeAsLooseText` read Windows-1252 INI
    /// titles as Shift-JIS ("Pokémon Empyrean" imported into
    /// `Pok駑on Empyrean/`). Returns the sanitized title exactly
    /// when the current folder name is that title's legacy mojibake
    /// rendering. Returns nil otherwise, so a folder never renames
    /// on a guess. `title` is the game's title as the FIXED decoder
    /// reads it today.
    public static func mojibakeRenameTarget(folderName: String, title: String) -> String? {
        let target = GameFolderName.sanitize(title)
        guard target != folderName,
            DirectoryNameMatch.legacyMojibakeRendering(of: target) == folderName
        else { return nil }
        return target
    }

    /// `"<uuid>-pokemon-uranium"` -> `"pokemon uranium"`. Returns nil
    /// when the legacy name has no slug part. Last-resort title source
    /// for legacy containers with no INI title and no metadata.
    public static func slugTitle(fromLegacyFolderName folderName: String) -> String? {
        guard legacyUUIDPrefix(folderName: folderName) != nil else { return nil }
        guard folderName.count > 37 else { return nil }
        let slug = String(folderName.dropFirst(37))
        let words = slug.split(separator: "-").filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }
}

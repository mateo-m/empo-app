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

    /// The `<uuid>` prefix of a pre-v0.5 `<uuid>-<slug>` folder name
    /// (the old container id), or nil for post-migration
    /// title-based names.
    public static func legacyUUIDPrefix(folderName: String) -> String? {
        guard folderName.count >= 36 else { return nil }
        let uuidPart = String(folderName.prefix(36))
        guard UUID(uuidString: uuidPart) != nil else { return nil }
        return uuidPart
    }

    /// `"<uuid>-pokemon-uranium"` -> `"pokemon uranium"`. Nil when
    /// the legacy name has no slug part. Last-resort title source
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

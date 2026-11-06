import Foundation

/// One game a run may cover, with the three values the order of SPEC
/// 7.8 reads.
public struct RunCandidate: Equatable, Sendable {

    public var gameKey: String
    /// The last run that closed a whole snapshot of this game on
    /// this target. `nil` means the game has never had one.
    public var lastSuccessAt: Date?
    /// When the user last played it.
    public var lastPlayedAt: Date?
    /// What this game would upload now.
    public var pendingBytes: Int64

    public init(
        gameKey: String,
        lastSuccessAt: Date? = nil,
        lastPlayedAt: Date? = nil,
        pendingBytes: Int64 = 0
    ) {
        self.gameKey = gameKey
        self.lastSuccessAt = lastSuccessAt
        self.lastPlayedAt = lastPlayedAt
        self.pendingBytes = pendingBytes
    }
}

/// The order of SPEC 7.8: risk, then recency, then smallest pending
/// bytes.
///
/// One game at a time, never in parallel. The prefs stream goes
/// first on every run, and the engine puts it there, because it is
/// not a game and so it never enters this list.
///
/// The clock is a parameter. A `Date()` call inside the function
/// would make the test unrepeatable.
public enum RunOrdering {

    /// When a game that was played goes stale, per 7.1. Ticket 007
    /// owns the rest of the staleness clock. The order needs this
    /// one mark, because rule 1 of 7.8 reads it.
    public static let staleMark: TimeInterval = 7 * 86_400

    /// Whether a game is past the stale mark. A game that never had
    /// a successful snapshot is past it.
    public static func isStale(lastSuccessAt: Date?, now: Date) -> Bool {
        guard let lastSuccessAt else { return true }
        return now.timeIntervalSince(lastSuccessAt) >= staleMark
    }

    /// The candidates in the order the run covers them.
    ///
    /// 1. Games past the stale mark first, oldest successful
    ///    snapshot leading.
    /// 2. Then the most recently played.
    /// 3. Then smallest pending bytes, so a short run clears several
    ///    games instead of dying inside one 4 GB tree.
    ///
    /// The game key closes the order, so two games that match on all
    /// three still sort the same way on every run.
    public static func order(_ candidates: [RunCandidate], now: Date) -> [RunCandidate] {
        candidates.sorted { left, right in
            let leftStale = isStale(lastSuccessAt: left.lastSuccessAt, now: now)
            let rightStale = isStale(lastSuccessAt: right.lastSuccessAt, now: now)
            if leftStale != rightStale { return leftStale }

            if leftStale {
                // Oldest successful snapshot leading. A game that
                // never had one leads them all.
                let leftSuccess = left.lastSuccessAt ?? .distantPast
                let rightSuccess = right.lastSuccessAt ?? .distantPast
                if leftSuccess != rightSuccess { return leftSuccess < rightSuccess }
            }

            let leftPlayed = left.lastPlayedAt ?? .distantPast
            let rightPlayed = right.lastPlayedAt ?? .distantPast
            if leftPlayed != rightPlayed { return leftPlayed > rightPlayed }

            if left.pendingBytes != right.pendingBytes {
                return left.pendingBytes < right.pendingBytes
            }
            return left.gameKey < right.gameKey
        }
    }
}

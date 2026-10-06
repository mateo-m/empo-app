import Foundation

/// What one target knows of the sync document, per SPEC 10.5.
public struct SyncTargetProgress: Codable, Equatable, Sendable {

    public var targetId: String
    /// The document heads `confirm` reported for this target, sorted.
    public var confirmedHeads: [String]
    /// The modified time of each namespace copy this device already
    /// merged, per 10.5 step 1. A target that reports no object age
    /// leaves it empty, and the pass reads every copy.
    public var seenNamespaces: [String: Date]

    public init(
        targetId: String, confirmedHeads: [String] = [], seenNamespaces: [String: Date] = [:]
    ) {
        self.targetId = targetId
        self.confirmedHeads = confirmedHeads.sorted()
        self.seenNamespaces = seenNamespaces
    }

    /// Whether one namespace copy is worth reading again.
    public func readsAgain(namespaceId: String, modifiedAt: Date?) -> Bool {
        guard let modifiedAt, let seen = seenNamespaces[namespaceId] else { return true }
        return modifiedAt > seen
    }
}

/// The pass of 10.5, as the rules that decide what it uploads.
///
/// Steps 1 to 4 read and merge. These are steps 5 and 6: which
/// targets take a copy, and when a target counts as current.
public enum SyncReplication {

    /// A target is current once it holds the same heads as the local
    /// document. A target Empo never confirmed is not current, and a
    /// newly added target is that case, so it takes the full known
    /// history before Empo calls it current.
    public static func isCurrent(_ progress: SyncTargetProgress, heads: [String]) -> Bool {
        !heads.isEmpty && progress.confirmedHeads == heads.sorted()
    }

    /// The targets one pass uploads to, in a stable order.
    ///
    /// A paused target takes nothing, per 8.8.
    public static func targetsNeedingACopy(
        enabled: [String], progress: [SyncTargetProgress], heads: [String]
    ) -> [String] {
        let byId = Dictionary(uniqueKeysWithValues: progress.map { ($0.targetId, $0) })
        return enabled.sorted().filter {
            guard let known = byId[$0] else { return true }
            return !isCurrent(known, heads: heads)
        }
    }
}

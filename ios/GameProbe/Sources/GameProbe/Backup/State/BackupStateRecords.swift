import Foundation

/// The newest manifest Empo uploaded for one game to one target, per
/// SPEC 6.2. The next run diffs against it.
public struct UploadedManifestRecord: Equatable, Sendable {
    public var targetId: String
    public var gameKey: String
    public var snapshotId: String
    public var manifest: SnapshotManifest
    public var uploadedAt: Date

    public init(
        targetId: String,
        gameKey: String,
        snapshotId: String,
        manifest: SnapshotManifest,
        uploadedAt: Date
    ) {
        self.targetId = targetId
        self.gameKey = gameKey
        self.snapshotId = snapshotId
        self.manifest = manifest
        self.uploadedAt = uploadedAt
    }
}

/// Where a run stopped, so the next one carries on instead of
/// starting again, per SPEC 6.2.
public struct RunCheckpoint: Equatable, Sendable {
    public var targetId: String
    public var gameKey: String
    public var snapshotId: String
    public var uploadedBytes: Int64
    /// The member paths that still have no confirmed blob.
    public var pendingPaths: [String]
    public var updatedAt: Date

    public init(
        targetId: String,
        gameKey: String,
        snapshotId: String,
        uploadedBytes: Int64 = 0,
        pendingPaths: [String] = [],
        updatedAt: Date
    ) {
        self.targetId = targetId
        self.gameKey = gameKey
        self.snapshotId = snapshotId
        self.uploadedBytes = uploadedBytes
        self.pendingPaths = pendingPaths
        self.updatedAt = updatedAt
    }
}

/// A game whose files changed since its last snapshot, per SPEC 6.2.
/// The app-background pass picks these up.
public struct DirtyMark: Equatable, Sendable {
    public var gameKey: String
    public var markedAt: Date
    /// What made the game dirty. Ticket 007 owns the triggers.
    public var reason: String

    public init(gameKey: String, markedAt: Date, reason: String) {
        self.gameKey = gameKey
        self.markedAt = markedAt
        self.reason = reason
    }
}

/// A backup delete the app took while the target was unreachable, per
/// SPEC 5.13. It applies at the start of the next successful run.
public struct PendingDeletion: Equatable, Sendable {
    public var targetId: String
    public var gameKey: String
    public var requestedAt: Date
    /// The `Rescued Saves` buckets the delete covers, per 5.13.
    public var rescuedBuckets: [String]

    public init(
        targetId: String,
        gameKey: String,
        requestedAt: Date,
        rescuedBuckets: [String] = []
    ) {
        self.targetId = targetId
        self.gameKey = gameKey
        self.requestedAt = requestedAt
        self.rescuedBuckets = rescuedBuckets
    }
}

/// How fresh one game is on one target, per SPEC 6.2. The per-game
/// badge reads it on every library refresh.
public struct StalenessClock: Equatable, Sendable {
    public var targetId: String
    public var gameKey: String
    /// The last run that closed a whole snapshot.
    public var lastSuccessAt: Date?
    /// The last run that tried, whatever it ended as.
    public var lastAttemptAt: Date?
    /// When the game first went partial, per 7.2. A partial snapshot
    /// does not stop this clock.
    public var partialSince: Date?

    public init(
        targetId: String,
        gameKey: String,
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        partialSince: Date? = nil
    ) {
        self.targetId = targetId
        self.gameKey = gameKey
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.partialSince = partialSince
    }
}

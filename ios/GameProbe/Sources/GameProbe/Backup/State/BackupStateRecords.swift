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
    /// The blobs this run already put on the target and confirmed
    /// durable.
    ///
    /// A run that died before its manifest landed leaves those blobs
    /// orphaned, per 5.8. `known_blob` cannot hold them, because a
    /// blob counts as known present only once a manifest that names
    /// it uploaded, per 6.2. This list is the weaker claim the
    /// resumed run reads, so it reuses the orphans for free instead
    /// of paying for the bytes twice.
    public var confirmedBlobs: [ConfirmedBlob]
    public var updatedAt: Date

    public init(
        targetId: String,
        gameKey: String,
        snapshotId: String,
        uploadedBytes: Int64 = 0,
        pendingPaths: [String] = [],
        confirmedBlobs: [ConfirmedBlob] = [],
        updatedAt: Date
    ) {
        self.targetId = targetId
        self.gameKey = gameKey
        self.snapshotId = snapshotId
        self.uploadedBytes = uploadedBytes
        self.pendingPaths = pendingPaths
        self.confirmedBlobs = confirmedBlobs
        self.updatedAt = updatedAt
    }
}

/// One blob a run put on the target and confirmed, with the
/// algorithm it went up with.
///
/// The algorithm rides with the hash because the hash alone cannot
/// give it back. The blob names the content, and 5.6 chooses the
/// algorithm per blob, so a manifest that reused a blob must record
/// what that blob was written with.
public struct ConfirmedBlob: Equatable, Sendable {

    public var hash: String
    public var compression: BlobCompression

    public init(hash: String, compression: BlobCompression) {
        self.hash = hash
        self.compression = compression
    }

    /// `<hash>:<algorithm>`, the form the checkpoint column holds.
    public var text: String {
        "\(hash):\(compression.rawValue)"
    }

    public init?(text: String) {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
            let compression = BlobCompression(rawValue: String(parts[1]))
        else { return nil }
        self.init(hash: String(parts[0]), compression: compression)
    }
}

/// One snapshot the ledger of SPEC 5.10 holds, so the prune knows
/// what a stream carries without listing the target.
public struct SnapshotLedgerEntry: Equatable, Sendable {
    public var targetId: String
    public var gameKey: String
    public var snapshotId: String
    public var createdAt: Date
    /// The one-off full snapshot of 5.15. It keeps its own retention
    /// rule of one, so only the newest one survives a prune.
    public var isOneOff: Bool

    public init(
        targetId: String,
        gameKey: String,
        snapshotId: String,
        createdAt: Date,
        isOneOff: Bool = false
    ) {
        self.targetId = targetId
        self.gameKey = gameKey
        self.snapshotId = snapshotId
        self.createdAt = createdAt
        self.isOneOff = isOneOff
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

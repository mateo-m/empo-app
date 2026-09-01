import Foundation

/// What one stream did.
public enum StreamOutcome: Equatable, Sendable {
    /// The snapshot went up, manifest last.
    case wroteSnapshot(snapshotId: String)
    /// No blob was new, so no snapshot was written and nothing
    /// uploaded, per 7.7.
    case noChange
    /// Not even the in-place path fits, per rule 6 of 6.4. The run
    /// stops for this game and carries on with the next.
    case notEnoughLocalSpace
    /// Every blob went up and the manifest did not, so the target
    /// holds no snapshot for this run, per 5.8.
    case blobsOnly
    case failed(reason: String)
}

public struct StreamResult: Equatable, Sendable {

    public var streamKey: String
    public var outcome: StreamOutcome
    public var uploadedBytes: Int64
    public var uploadedBlobCount: Int
    /// The paths the snapshot marked partial, per 5.9.
    public var partialPaths: [String]
    /// The snapshots the prune of 5.10 dropped.
    public var prunedSnapshotIds: [String]

    public init(
        streamKey: String,
        outcome: StreamOutcome,
        uploadedBytes: Int64 = 0,
        uploadedBlobCount: Int = 0,
        partialPaths: [String] = [],
        prunedSnapshotIds: [String] = []
    ) {
        self.streamKey = streamKey
        self.outcome = outcome
        self.uploadedBytes = uploadedBytes
        self.uploadedBlobCount = uploadedBlobCount
        self.partialPaths = partialPaths
        self.prunedSnapshotIds = prunedSnapshotIds
    }
}

/// Why a run stopped before it covered every stream.
public enum BackupRunStop: Error, Equatable, Sendable {
    /// `writer.json` names another device, per 5.12. The run wrote
    /// nothing. The caller asks, and the default is a split.
    case writerConflict(WriterClaim)
    /// The target or the namespace carries a format this build may
    /// not write, per 5.16.
    case readOnlyFormat(FormatAccess.Restriction)
    /// The token or the password no longer works, per 8.4.
    case needsSignIn
    /// The scope or the folder rights do not cover the operation,
    /// per 8.4. A re-sign-in with full access is what fixes it.
    case blocked(reason: String)
    /// Quota or cap reached after the prune ladder of 5.14 ran out.
    case full(reason: String)
    /// A space query answered before staging and the run cannot fit,
    /// per 5.14.
    case quotaShortfall(QuotaCheck.Shortfall)
    /// The device has no route to the target. Transient, per 7.11.
    case offline
    /// The service asked Empo to wait. Transient, per 7.11, so it
    /// notifies nothing and waits for the next run.
    case throttled(retryAfter: TimeInterval)
    /// The service refused and gave a reason, per 8.4.
    case rejected(message: String)
}

public struct BackupRunResult: Equatable, Sendable {

    public var runId: String
    /// The namespace the run wrote. A split changes it, and the
    /// caller stores the new id.
    public var namespaceId: String
    public var outcome: BackupRunOutcome
    public var uploadedBytes: Int64
    public var streams: [StreamResult]
    public var stop: BackupRunStop?
    /// The run split off a new namespace, per 5.12. It is not a
    /// failure and it never notifies, per 7.11.
    public var didSplit: Bool
    /// The line the run history row carries, per 6.6.
    public var detail: String?

    public init(
        runId: String,
        namespaceId: String,
        outcome: BackupRunOutcome,
        uploadedBytes: Int64 = 0,
        streams: [StreamResult] = [],
        stop: BackupRunStop? = nil,
        didSplit: Bool = false,
        detail: String? = nil
    ) {
        self.runId = runId
        self.namespaceId = namespaceId
        self.outcome = outcome
        self.uploadedBytes = uploadedBytes
        self.streams = streams
        self.stop = stop
        self.didSplit = didSplit
        self.detail = detail
    }

    public func stream(_ key: String) -> StreamResult? {
        streams.first { $0.streamKey == key }
    }
}

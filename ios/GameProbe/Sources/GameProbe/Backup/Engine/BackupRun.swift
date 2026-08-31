import Foundation

/// One game a run covers.
public struct BackupRunGame: Sendable {

    public var identity: GameIdentity
    /// What the resolver of 3 reads to enumerate the backup set.
    public var set: GameBackupSetRequest
    /// The marker of 4.4, which the manifest header records.
    public var versionMarker: SnapshotManifest.VersionMarker
    /// When the user last played it. The order of 7.8 reads it.
    public var lastPlayedAt: Date?
    /// The game still has a local container. A game without one
    /// keeps its newest 3 snapshots, per 5.10.
    public var hasLocalContainer: Bool
    /// The one-off full snapshot of 5.15. It counts against quota in
    /// full, it keeps its own retention rule of one, and it does not
    /// change the game's mode.
    public var isOneOffFullSnapshot: Bool

    public init(
        identity: GameIdentity,
        set: GameBackupSetRequest,
        versionMarker: SnapshotManifest.VersionMarker = SnapshotManifest.VersionMarker(),
        lastPlayedAt: Date? = nil,
        hasLocalContainer: Bool = true,
        isOneOffFullSnapshot: Bool = false
    ) {
        self.identity = identity
        self.set = set
        self.versionMarker = versionMarker
        self.lastPlayedAt = lastPlayedAt
        self.hasLocalContainer = hasLocalContainer
        self.isOneOffFullSnapshot = isOneOffFullSnapshot
    }

    public var stream: BackupStream {
        .game(key: identity.gameKey)
    }
}

/// One run against one target.
///
/// The engine takes its clock, its filesystem root, and its provider
/// as inputs, so a test drives all three. Free space is an input too,
/// per 6.4, because a volume read inside the engine would make the
/// budget rules depend on the host.
public struct BackupRunRequest: Sendable {

    public var runId: String
    public var descriptor: TargetDescriptor
    public var namespaceId: String
    public var deviceId: String
    public var deviceName: String
    public var deviceModel: String
    public var retentionPreset: RetentionPreset
    public var freeSpaceBytes: Int64
    /// The stream that belongs to no game, per 5.3. It goes first on
    /// every run.
    public var preferences: LibraryBackupSetRequest?
    public var games: [BackupRunGame]
    /// What the user chose after a writer mismatch, per 5.12. A run
    /// that meets a mismatch with no choice stops and asks.
    public var writerResolution: WriterClaimResolution?
    /// The namespace a split writes to. The caller makes it with
    /// `BackupKeys.makeNamespaceId()` and stores it in the Keychain,
    /// per 5.2.
    public var splitNamespaceId: String?

    public init(
        runId: String,
        descriptor: TargetDescriptor,
        namespaceId: String,
        deviceId: String,
        deviceName: String,
        deviceModel: String = "",
        retentionPreset: RetentionPreset = .standard,
        freeSpaceBytes: Int64 = .max,
        preferences: LibraryBackupSetRequest? = nil,
        games: [BackupRunGame] = [],
        writerResolution: WriterClaimResolution? = nil,
        splitNamespaceId: String? = nil
    ) {
        self.runId = runId
        self.descriptor = descriptor
        self.namespaceId = namespaceId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.retentionPreset = retentionPreset
        self.freeSpaceBytes = freeSpaceBytes
        self.preferences = preferences
        self.games = games
        self.writerResolution = writerResolution
        self.splitNamespaceId = splitNamespaceId
    }
}

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

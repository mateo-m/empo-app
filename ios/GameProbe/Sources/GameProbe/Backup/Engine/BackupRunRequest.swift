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
    /// The sync group this device joined, per 10.4. The run carries
    /// it into `device.json`, which is where a second device of the
    /// same person finds the group, per 10.5 step 1.
    public var syncGroupId: String?

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
        splitNamespaceId: String? = nil,
        syncGroupId: String? = nil
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
        self.syncGroupId = syncGroupId
    }
}

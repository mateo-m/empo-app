import Foundation

/// One restore, as the engine needs it.
///
/// The planner of ticket 014's pure half decides what happens. This
/// carries the paths and the numbers only the app can answer.
public struct RestoreRequest: Sendable {

    public var restoreId: String
    /// The target the snapshot is on. A backup package carries its
    /// own id here, because a package is not a target, per 12.7.
    public var targetId: String
    /// The fixed root of 8.7, or an empty string for a package.
    public var root: String
    public var namespaceId: String
    /// The stream the snapshot belongs to, per 5.3.
    public var stream: BackupStream
    public var snapshotId: String
    public var scope: RestoreScope
    /// Where each named root of the manifest writes on this device.
    public var destination: MemberSource
    /// Every file the local tree already holds under those roots,
    /// displaced copies included.
    public var localFiles: [RestoreLocalFile]
    public var localVersionMarker: SnapshotManifest.VersionMarker?
    public var freeSpaceBytes: Int64
    /// The replace choice of 11.12. Only "Use only this backup"
    /// sets it.
    public var replacesTheTree: Bool
    /// The game's mode, which gates proven coverage.
    public var mode: BackupMode
    /// `Documents/Games/<folderName>/Game/`, the tree a replace
    /// moves aside.
    public var gameTreeURL: URL?

    public init(
        restoreId: String = UUID().uuidString,
        targetId: String,
        root: String,
        namespaceId: String,
        stream: BackupStream,
        snapshotId: String,
        scope: RestoreScope,
        destination: MemberSource,
        localFiles: [RestoreLocalFile] = [],
        localVersionMarker: SnapshotManifest.VersionMarker? = nil,
        freeSpaceBytes: Int64,
        replacesTheTree: Bool = false,
        mode: BackupMode = .slim,
        gameTreeURL: URL? = nil
    ) {
        self.restoreId = restoreId
        self.targetId = targetId
        self.root = root
        self.namespaceId = namespaceId
        self.stream = stream
        self.snapshotId = snapshotId
        self.scope = scope
        self.destination = destination
        self.localFiles = localFiles
        self.localVersionMarker = localVersionMarker
        self.freeSpaceBytes = freeSpaceBytes
        self.replacesTheTree = replacesTheTree
        self.mode = mode
        self.gameTreeURL = gameTreeURL
    }
}

/// What a finished restore did.
public struct RestoreResult: Equatable, Sendable {
    public var writtenFileCount = 0
    public var displacedFileCount = 0
    public var unchangedFileCount = 0
    public var partialPathCount = 0
    public var bytesWritten: Int64 = 0
    /// The name the replaced tree took, per 11.12.
    public var replacedTreeName: String?
    /// How many files proven coverage let the replaced tree drop.
    public var droppedFromReplacedTree = 0
    /// What the replaced tree still holds.
    public var replacedTreeKeptBytes: Int64 = 0
}

/// How a restore ended.
public enum RestoreOutcome: Sendable {
    case finished(RestoreResult)
    /// The space check of 11.8 refused before any write.
    case notEnoughSpace(RestoreSpaceCheck.Shortfall)
    /// It started and stopped. Everything already written stays, and
    /// the originals stay safe as displaced copies.
    case stopped(RestoreStopReason, RestoreResult)
    case failed(String)
}

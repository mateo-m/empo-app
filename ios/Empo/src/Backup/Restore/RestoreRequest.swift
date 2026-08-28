import Foundation
import GameProbe

/// One restore, as the engine needs it.
///
/// The planner of ticket 014's pure half decides what happens. This
/// carries the paths and the numbers only the app can answer.
struct RestoreRequest: Sendable {

    var restoreId: String
    var descriptor: TargetDescriptor
    var namespaceId: String
    /// The stream the snapshot belongs to, per 5.3.
    var stream: BackupStream
    var snapshotId: String
    var scope: RestoreScope
    /// Where each named root of the manifest writes on this device.
    var destination: MemberSource
    /// Every file the local tree already holds under those roots,
    /// displaced copies included.
    var localFiles: [RestoreLocalFile]
    var localVersionMarker: SnapshotManifest.VersionMarker?
    var freeSpaceBytes: Int64
    /// The replace choice of 11.12. Only "Use only this backup"
    /// sets it.
    var replacesTheTree: Bool
    /// The game's mode, which gates proven coverage.
    var mode: BackupMode
    /// `Documents/Games/<folderName>/Game/`, the tree a replace
    /// moves aside.
    var gameTreeURL: URL?

    init(
        restoreId: String = UUID().uuidString,
        descriptor: TargetDescriptor,
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
        self.descriptor = descriptor
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
struct RestoreResult: Equatable, Sendable {
    var writtenFileCount = 0
    var displacedFileCount = 0
    var unchangedFileCount = 0
    var partialPathCount = 0
    var bytesWritten: Int64 = 0
    /// The name the replaced tree took, per 11.12.
    var replacedTreeName: String?
    /// How many files proven coverage let the replaced tree drop.
    var droppedFromReplacedTree = 0
    /// What the replaced tree still holds.
    var replacedTreeKeptBytes: Int64 = 0
}

/// How a restore ended.
enum RestoreOutcome: Sendable {
    case finished(RestoreResult)
    /// The space check of 11.8 refused before any write.
    case notEnoughSpace(RestoreSpaceCheck.Shortfall)
    /// It started and stopped. Everything already written stays, and
    /// the originals stay safe as displaced copies.
    case stopped(RestoreStopReason, RestoreResult)
    case failed(String)
}

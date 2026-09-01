import Foundation

/// What a package build is doing now, per SPEC 12.5.
public struct PackageBuildProgress: Equatable, Sendable {
    public var fileCount = 0
    public var totalFileCount = 0
    public var bytes: Int64 = 0
    public var totalBytes: Int64 = 0

    public init(
        fileCount: Int = 0, totalFileCount: Int = 0, bytes: Int64 = 0, totalBytes: Int64 = 0
    ) {
        self.fileCount = fileCount
        self.totalFileCount = totalFileCount
        self.bytes = bytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytes) / Double(totalBytes))
    }
}

public enum PackageBuildFailure: Error {
    case notEnoughSpace(Int64)
    case cancelled
    case failed(String)
}

/// What one export writes, per SPEC 12.4 and 12.5.
///
/// An export reads current device data. It writes one current
/// snapshot per game and one current copy of each shared stream, and
/// it never copies retained history from a target.
public struct PackagePlan: Sendable {

    /// One game, or the whole library.
    public var gameName: String?
    public var streams: [Stream]

    public init(gameName: String?, streams: [Stream]) {
        self.gameName = gameName
        self.streams = streams
    }

    public struct Stream: Sendable {
        public var key: String
        public var gameName: String?
        public var mode: BackupMode
        public var containerFolderName: String
        public var identityAlias: String?
        public var versionMarker: SnapshotManifest.VersionMarker
        public var sharedDataDirectory: String?
        public var rescuedSavesBuckets: [String]
        public var members: [BackupSetMember]
        public var source: MemberSource

        public init(
            key: String,
            gameName: String?,
            mode: BackupMode,
            containerFolderName: String,
            identityAlias: String? = nil,
            versionMarker: SnapshotManifest.VersionMarker,
            sharedDataDirectory: String? = nil,
            rescuedSavesBuckets: [String],
            members: [BackupSetMember],
            source: MemberSource
        ) {
            self.key = key
            self.gameName = gameName
            self.mode = mode
            self.containerFolderName = containerFolderName
            self.identityAlias = identityAlias
            self.versionMarker = versionMarker
            self.sharedDataDirectory = sharedDataDirectory
            self.rescuedSavesBuckets = rescuedSavesBuckets
            self.members = members
            self.source = source
        }
    }

    public var sourceBytes: Int64 {
        streams.reduce(0) { $0 + $1.members.reduce(0) { $0 + $1.size } }
    }

    public var fileCount: Int {
        streams.reduce(0) { $0 + $1.members.count }
    }

    // MARK: - The build, per 12.5

    /// Writes the ZIP into the staging area and answers where it is.
    ///
    /// It hashes each file, then writes it, so the manifest carries
    /// the SHA-256 of exactly the bytes the ZIP holds.
    public func build(
        id: String = UUID().uuidString,
        localRoot: URL,
        sourceDevice: String,
        freeSpaceBytes: Int64,
        at date: Date = Date(),
        onProgress: @escaping @Sendable (PackageBuildProgress) -> Void = { _ in }
    ) throws -> PackageRecord {
        if let shortfall = PackageDoors.shortfall(
            sourceBytes: sourceBytes, freeSpaceBytes: freeSpaceBytes)
        {
            throw PackageBuildFailure.notEnoughSpace(shortfall)
        }

        let fileName = PackageLayout.fileName(gameName: gameName, date: date)
        let directory = BackupRootLayout(root: localRoot).package(id: id)
        let zipURL = directory.appendingPathComponent(fileName)
        let writer = try ZipWriter(creating: zipURL)

        var progress = PackageBuildProgress(totalFileCount: fileCount, totalBytes: sourceBytes)
        var written: [PackageStream] = []

        do {
            for planned in streams {
                var entries: [SnapshotManifest.Entry] = []
                var manifest = SnapshotManifest(
                    mode: planned.mode,
                    containerFolderName: planned.containerFolderName,
                    identityAlias: planned.identityAlias,
                    versionMarker: planned.versionMarker,
                    sharedDataDirectory: planned.sharedDataDirectory,
                    rescuedSavesBuckets: planned.rescuedSavesBuckets)

                for member in planned.members {
                    try Task.checkCancellation()
                    guard let file = planned.source.url(of: member),
                        let hash = try? ContentHash.hexOfFile(at: file)
                    else { continue }

                    let entry = SnapshotManifest.Entry(
                        root: member.root,
                        path: member.path,
                        size: member.size,
                        modifiedAt: member.modifiedAt,
                        hash: hash,
                        // A package stores each file at its own
                        // path, so nothing here is a compressed
                        // blob, per 12.3.
                        compression: .stored,
                        detectionSource: member.detectionSource)
                    guard let path = PackageLayout.zipPath(of: entry, in: manifest) else {
                        continue
                    }
                    try writer.add(file: file, at: path, modifiedAt: member.modifiedAt)
                    entries.append(entry)

                    progress.fileCount += 1
                    progress.bytes += member.size
                    onProgress(progress)
                }

                manifest.entries = entries
                written.append(
                    PackageStream(
                        key: planned.key, gameName: planned.gameName, manifest: manifest))
            }

            let manifest = PackageManifest(
                exportedAt: date, sourceDevice: sourceDevice, streams: written)
            try writer.add(data: Data(PackageLayout.readmeText.utf8), at: PackageLayout.readmePath)
            try writer.add(data: try manifest.jsonData(), at: PackageLayout.manifestPath)
            try writer.finish()
        } catch is CancellationError {
            // A cancelled build deletes the partial ZIP, per 12.5.
            writer.cancel()
            try? FileManager.default.removeItem(at: directory)
            throw PackageBuildFailure.cancelled
        } catch {
            writer.cancel()
            try? FileManager.default.removeItem(at: directory)
            throw PackageBuildFailure.failed(String(describing: error))
        }

        let record = PackageRecord(
            id: id, kind: .built, fileName: fileName, gameName: gameName,
            createdAt: date, isSaved: false)
        record.save(in: directory)
        return record
    }
}

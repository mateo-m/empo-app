import Foundation
import GameProbe
import UIKit

/// What a package build is doing now, per SPEC 12.5.
struct PackageBuildProgress: Equatable, Sendable {
    var fileCount = 0
    var totalFileCount = 0
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytes) / Double(totalBytes))
    }
}

enum PackageBuildFailure: Error {
    case notEnoughSpace(Int64)
    case cancelled
    case failed(String)
}

/// Builds a backup package, per SPEC 12.4 and 12.5.
///
/// An export reads current device data. It writes one current
/// snapshot per game and one current copy of each shared stream, and
/// it never copies retained history from a target.
enum PackageExport {

    /// One game, or the whole library.
    struct Plan: Sendable {
        var gameName: String?
        var streams: [PlannedStream]

        var sourceBytes: Int64 {
            streams.reduce(0) { $0 + $1.members.reduce(0) { $0 + $1.size } }
        }

        var fileCount: Int {
            streams.reduce(0) { $0 + $1.members.count }
        }
    }

    struct PlannedStream: Sendable {
        var key: String
        var gameName: String?
        var mode: BackupMode
        var containerFolderName: String
        var identityAlias: String?
        var versionMarker: SnapshotManifest.VersionMarker
        var sharedDataDirectory: String?
        var rescuedSavesBuckets: [String]
        var members: [BackupSetMember]
        var source: MemberSource
    }

    // MARK: - What goes in, per 12.4

    /// The plan for one game. It uses that game's current mode.
    @MainActor
    static func plan(game container: GameContainer) async -> Plan {
        let name = Self.name(of: container)
        return Plan(gameName: name, streams: [await stream(of: container, gameName: name)])
    }

    /// The plan for the whole library: each game at its current
    /// mode, plus the preferences stream, the layout profiles, and
    /// the Rescued Saves tree.
    @MainActor
    static func libraryPlan() async -> Plan {
        var streams: [PlannedStream] = []
        for container in GameContainer.discover() {
            streams.append(await stream(of: container, gameName: Self.name(of: container)))
        }
        if let preferences = preferencesStream() { streams.append(preferences) }
        return Plan(gameName: nil, streams: streams)
    }

    @MainActor
    private static func stream(
        of container: GameContainer, gameName: String
    ) async -> PlannedStream {
        let mode = await self.mode(of: container)
        let request = GameBackupSets.request(for: container, mode: mode)
        let set = BackupSetResolver.resolve(request)
        let identity = GameIdentities.identity(for: container)
        return PlannedStream(
            key: identity.gameKey,
            gameName: gameName,
            mode: set.mode,
            containerFolderName: container.folderName,
            identityAlias: identity.aliases.last,
            versionMarker: GameIdentities.versionMarker(for: container),
            sharedDataDirectory: set.sharedDataDirectory,
            rescuedSavesBuckets: set.rescuedSavesBuckets,
            members: set.members,
            source: MemberSource(game: request))
    }

    /// The stream that belongs to no game, per 5.3, with the
    /// UserDefaults export of 10.1 written into staging first.
    @MainActor
    private static func preferencesStream() -> PlannedStream? {
        guard let file = DevicePreferences.writeTheExportFile() else { return nil }
        let request = GameBackupSets.libraryRequest(userDefaultsExportFile: file)
        let set = BackupSetResolver.resolveLibraryStream(request)
        guard !set.members.isEmpty else { return nil }
        return PlannedStream(
            key: BackupStream.preferencesKey,
            gameName: nil,
            mode: set.mode,
            containerFolderName: "",
            versionMarker: SnapshotManifest.VersionMarker(),
            rescuedSavesBuckets: set.rescuedSavesBuckets,
            members: set.members,
            source: MemberSource(library: request))
    }

    @MainActor
    private static func mode(of container: GameContainer) async -> BackupMode {
        let resolution = await GameBackupSets.resolveMode(
            for: container, targets: BackupTargets.thresholds())
        // A game that never answered the ask of 3.5 exports its save
        // members, which is what the ask's own default is.
        guard case .mode(let mode) = resolution else { return .slim }
        return mode
    }

    @MainActor
    private static func name(of container: GameContainer) -> String {
        let metadata = GameMetadata.load(from: container)
        return metadata.customTitle ?? metadata.baseTitle ?? container.folderName
    }

    // MARK: - The build, per 12.5

    /// Writes the ZIP into the staging area and answers where it is.
    ///
    /// It hashes each file, then writes it, so the manifest carries
    /// the SHA-256 of exactly the bytes the ZIP holds.
    static func build(
        _ plan: Plan,
        id: String = UUID().uuidString,
        localRoot: URL,
        sourceDevice: String,
        freeSpaceBytes: Int64,
        at date: Date = Date(),
        onProgress: @escaping @Sendable (PackageBuildProgress) -> Void = { _ in }
    ) throws -> PackageRecord {
        if let shortfall = PackageDoors.shortfall(
            sourceBytes: plan.sourceBytes, freeSpaceBytes: freeSpaceBytes)
        {
            throw PackageBuildFailure.notEnoughSpace(shortfall)
        }

        let fileName = PackageLayout.fileName(gameName: plan.gameName, date: date)
        let directory = BackupRootLayout.package(root: localRoot, id: id)
        let zipURL = directory.appendingPathComponent(fileName)
        let writer = try ZipWriter(creating: zipURL)

        var progress = PackageBuildProgress(
            totalFileCount: plan.fileCount, totalBytes: plan.sourceBytes)
        var streams: [PackageStream] = []

        do {
            for planned in plan.streams {
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
                streams.append(
                    PackageStream(
                        key: planned.key, gameName: planned.gameName, manifest: manifest))
            }

            let manifest = PackageManifest(
                exportedAt: date, sourceDevice: sourceDevice, streams: streams)
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
            id: id, kind: .built, fileName: fileName, gameName: plan.gameName,
            createdAt: date, isSaved: false)
        record.save(in: directory)
        return record
    }
}

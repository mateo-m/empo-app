import Foundation
import GameProbe
import UIKit

/// The app-side half of SPEC 11: it hands the pure rules the paths
/// and the numbers only the app knows, and it owns the one running
/// restore.
///
/// One restore runs at a time. Launching a game cancels it at once,
/// per 7.6, and the cancel leaves the intent record of 6.5 plus the
/// staged blobs, so the next launch asks once.
///
@MainActor
final class RestoreCoordinator {

    static let shared = RestoreCoordinator()

    private var running: Task<RestoreOutcome, Never>?
    /// The game key of the restore in flight, so the manual door of
    /// 11.3 can close for that game alone.
    private(set) var runningGameKey: String?

    private init() {}

    // MARK: - The doors, per 11.3

    /// Whether the manual door is open for one game.
    func availability(gameKey: String) -> RestoreAvailability {
        RestorePicker.availability(
            runInFlight: runningGameKey == gameKey || BackupScheduler.shared.isRunning,
            gameIsPlaying: BackupDeviceConditions.isSessionLive)
    }

    /// Whether the fresh-install flow opens after a target was
    /// added, per 11.3.
    func freshInstallOpens(foundNamespaces: Bool, targetCount: Int) -> Bool {
        FreshInstallMerge.opens(
            libraryIsEmpty: GameContainer.discover().isEmpty,
            isFirstTarget: targetCount == 1,
            foundNamespaces: foundNamespaces)
    }

    /// Scans one target for the fresh-install screen of 11.4.
    func freshInstallPlan(
        descriptor: TargetDescriptor, provider: some BackupProvider
    ) async -> FreshInstallPlan? {
        let scan = RestoreScan(provider: provider, descriptor: descriptor)
        guard let namespaces = try? await scan.namespaces() else { return nil }

        let gameRows = namespaces.flatMap(\.gameRows)
        let preferencesRows = namespaces.flatMap(\.preferencesRows)
        let newestPreferences = RestorePicker.newestFirst(preferencesRows).first
        let buckets =
            namespaces
            .first { $0.id == newestPreferences?.namespaceId }?
            .rescuedSavesBuckets ?? []

        let streamed = BackupTargets.load().filter { $0.id != descriptor.id }
        return FreshInstallMerge.plan(
            gameRows: gameRows,
            preferencesRow: newestPreferences,
            orphanedBuckets: buckets,
            hints: FreshInstallHints.lines(
                streamed: streamed,
                canOpenICloud: await ICloudDriveGate.shared.availability().isReady),
            joinedSyncGroup: SyncStore.state().hasJoined)
    }

    // MARK: - Running one restore

    /// Starts a restore and waits for it.
    ///
    /// The caller has already answered the version-marker sheet of
    /// 11.10 where it fired, so `scope` and `replacesTheTree` carry
    /// that answer.
    func restore(
        _ row: SnapshotRow,
        into container: GameContainer?,
        provider: some BackupProvider,
        descriptor: TargetDescriptor,
        scope: RestoreScope,
        replacesTheTree: Bool = false
    ) async -> RestoreOutcome {
        let scan = RestoreScan(provider: provider, descriptor: descriptor)
        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: row.namespaceId)
        guard
            let manifest = try? await scan.manifest(
                at: paths.manifestPath(stream: Self.stream(of: row), snapshotId: row.snapshotId))
        else {
            return .failed(Self.unreadableLine)
        }
        return await run(
            row, into: container, provider: provider, targetId: descriptor.id,
            root: descriptor.root, manifest: manifest, scope: scope,
            replacesTheTree: replacesTheTree)
    }

    /// The import of 12.6. The package answers the provider protocol
    /// itself and carries its own manifest, so nothing scans it and
    /// the engine below runs unchanged.
    func restore(
        _ row: SnapshotRow,
        into container: GameContainer?,
        package: PackageSource,
        scope: RestoreScope,
        replacesTheTree: Bool = false
    ) async -> RestoreOutcome {
        guard let manifest = package.manifest.stream(Self.stream(of: row).key)?.manifest else {
            return .failed(Self.unreadableLine)
        }
        return await run(
            row, into: container, provider: package,
            targetId: PackageSource.targetId(packageId: package.packageId), root: "",
            manifest: manifest, scope: scope, replacesTheTree: replacesTheTree)
    }

    private func run(
        _ row: SnapshotRow,
        into container: GameContainer?,
        provider: some BackupProvider,
        targetId: String,
        root: String,
        manifest: SnapshotManifest,
        scope: RestoreScope,
        replacesTheTree: Bool
    ) async -> RestoreOutcome {
        guard running == nil else { return .failed("a restore is already running") }

        let destination = Self.destination(for: container, manifest: manifest)
        let request = RestoreRequest(
            targetId: targetId,
            root: root,
            namespaceId: row.namespaceId,
            stream: Self.stream(of: row),
            snapshotId: row.snapshotId,
            scope: scope,
            destination: destination,
            localFiles: Self.localFiles(
                destination: destination, manifest: manifest, scope: scope),
            localVersionMarker: container.map(GameIdentities.versionMarker(for:)),
            freeSpaceBytes: Self.freeSpaceBytes,
            replacesTheTree: replacesTheTree,
            mode: manifest.mode,
            gameTreeURL: container?.gameURL)

        let store: BackupStateStore
        do {
            store = try BackupStateStore(url: BackupRoot.layout.stateDatabase)
        } catch {
            return .failed("this device could not open its local state")
        }

        runningGameKey = container.map { BackupKeys.gameKey(containerFolderName: $0.folderName) }
        let localRoot = BackupRoot.layout.root
        let task = Task<RestoreOutcome, Never> {
            let engine = RestoreEngine(provider: provider, store: store, localRoot: localRoot)
            return await engine.run(request)
        }
        running = task
        let outcome = await task.value
        running = nil
        runningGameKey = nil
        // The rollback of 10.9. The stream carries one export file,
        // and applying it is what makes the snapshot the live
        // settings.
        if case .finished = outcome, request.stream == .preferences {
            PreferenceRestore.applyTheRestoredFile()
        }
        log("restore of \(row.snapshotId): \(outcome)")
        return outcome
    }

    /// The stream a row belongs to. The preferences stream of 5.3
    /// carries the game key of the empty container name, so one
    /// reading covers both kinds of row.
    private static func stream(of row: SnapshotRow) -> BackupStream {
        BackupStream(key: row.identity.gameKey)
    }

    private static let unreadableLine = "this backup could not be read"

    /// The hard stop of 7.6. A game launched, so the restore stops at
    /// once and leaves its record and its staged blobs.
    func stopForGameLaunch() {
        guard let running else { return }
        running.cancel()
        log("a game launched, so the restore stopped")
    }

    // MARK: - The resume question, per 11.9

    /// The record the next launch asks about, or `nil` when there is
    /// nothing to ask.
    func pendingResume() -> BackupIntentRecord? {
        guard let store = try? BackupStateStore(url: BackupRoot.layout.stateDatabase) else { return nil }
        defer { store.close() }
        // `try?` flattens the optional the store returns, so this is
        // one level, not two.
        let record = try? store.intent(kind: .interruptedRestore)
        return RestoreResumeQuestion.asks(record) ? record : nil
    }

    /// Continues the restore the record names, with the same scope
    /// and the same replace choice the user chose, per 11.7.
    ///
    /// The staged blobs are still there, so a resumed restore pays
    /// for the bytes it already downloaded once.
    @discardableResult
    func resume(_ record: BackupIntentRecord) async -> RestoreOutcome {
        if let packageId = PackageSource.packageId(ofTargetId: record.targetId) {
            return await resumeTheImport(packageId: packageId, record: record)
        }
        guard let descriptor = BackupTargets.load().first(where: { $0.id == record.targetId }),
            let provider = await BackupTargets.provider(for: descriptor),
            let snapshotId = record.snapshotId
        else { return .failed("this target is not configured on this device") }

        let scan = RestoreScan(provider: provider, descriptor: descriptor)
        guard let namespaces = try? await scan.namespaces(),
            let row = namespaces.flatMap({ $0.gameRows + $0.preferencesRows })
                .first(where: { $0.snapshotId == snapshotId })
        else { return .failed("this backup could not be read") }

        let container = record.gameKey.flatMap { key in
            GameContainer.discover().first {
                BackupKeys.gameKey(containerFolderName: $0.folderName) == key
            }
        }
        return await restore(
            row, into: container, provider: provider, descriptor: descriptor,
            scope: record.restoreScope ?? .savesAndSettings,
            replacesTheTree: record.replacesTheTree)
    }

    /// An import that stopped, per 12.6. The staged package is still
    /// in the staging area, so the resume opens it again and repeats
    /// the row the record names.
    private func resumeTheImport(
        packageId: String, record: BackupIntentRecord
    ) async -> RestoreOutcome {
        let localRoot = BackupRoot.layout.root
        guard
            let staged = PackageRecord.all(localRoot: localRoot).first(where: {
                $0.id == packageId
            }),
            let source = try? PackageSource(
                zip: staged.zipURL(localRoot: localRoot), packageId: packageId),
            let snapshotId = record.snapshotId,
            let row = PackageSource.rows(of: source.manifest, packageId: packageId)
                .first(where: { $0.snapshotId == snapshotId })
        else { return .failed("this backup package is no longer on this device") }

        return await restore(
            row, into: GameIdentities.match(row.identity), package: source,
            scope: record.restoreScope ?? .savesAndSettings,
            replacesTheTree: record.replacesTheTree)
    }

    /// Applies one answer. The caller resumes the restore itself when
    /// the effect says to start it now.
    func answerResume(_ action: RestoreResumeQuestion.Action, record: BackupIntentRecord) {
        guard let store = try? BackupStateStore(url: BackupRoot.layout.stateDatabase) else { return }
        defer { store.close() }

        // Every answer marks the record asked, because the question
        // was asked. That is what keeps one interruption from asking
        // twice.
        try? store.markIntentAsked(kind: .interruptedRestore)

        let effect = RestoreResumeQuestion.effect(of: action)
        guard !effect.keepsRecord else { return }
        try? store.clearIntent(kind: .interruptedRestore)
        guard effect.deletesStagedBlobs else { return }
        Self.deleteStagedBlobs()
        // Stopping an import deletes the staged package as well as
        // the staged files, per 12.6.
        if let packageId = PackageSource.packageId(ofTargetId: record.targetId) {
            PackageRecord.all(localRoot: BackupRoot.layout.root)
                .first { $0.id == packageId }?
                .delete(localRoot: BackupRoot.layout.root)
        }
    }

    private static func deleteStagedBlobs() {
        let fm = FileManager.default
        let directory = BackupRoot.layout.restore
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - The local side

    /// Where each named root of a manifest writes on this device,
    /// per 5.5 and 4.5.
    ///
    /// The manifest header carries the shared data directory as a
    /// path relative to `Documents/`, and the bucket names beside
    /// it, so a device that never held the game still knows where
    /// the outside members go.
    static func destination(
        for container: GameContainer?, manifest: SnapshotManifest
    ) -> MemberSource {
        var buckets: [String: URL] = [:]
        for name in manifest.rescuedSavesBuckets {
            buckets[name] = DataDirectory.rescuedSavesRootURL
                .appendingPathComponent(name, isDirectory: true)
        }
        return MemberSource(
            container: container?.url,
            sharedData: manifest.sharedDataDirectory.map {
                DataDirectory.documentsRootURL.appendingPathComponent($0)
            },
            rescuedBuckets: buckets,
            profiles: LayoutProfilesManager.profilesRootURL,
            userDefaultsExport: PreferenceRestore.restoredFile)
    }

    /// Every local file the plan has to know about.
    ///
    /// Two kinds go in. The files the snapshot names, so the planner
    /// can tell a write from a displacement, and every other name in
    /// the directories it touches, so a second displacement of one
    /// file numbers against the names already there.
    ///
    /// A hash costs a full read, so it is read only where the local
    /// size matches the entry's. A file of a different size can
    /// never hold the same content.
    static func localFiles(
        destination: MemberSource, manifest: SnapshotManifest, scope: RestoreScope
    ) -> [RestoreLocalFile] {
        let fm = FileManager.default
        var files: [RestoreLocalFile] = []
        var seen: Set<String> = []
        var directories: Set<Folder> = []

        for entry in manifest.entries where scope.covers(entry) {
            directories.insert(Folder(root: entry.root, path: directory(of: entry.path)))
            guard let url = destination.url(of: entry),
                let stamp = BackupSetResolver.stamp(of: url, fm: fm)
            else { continue }
            seen.insert(key(entry.root, entry.path))
            files.append(
                RestoreLocalFile(
                    root: entry.root,
                    path: entry.path,
                    size: stamp.size,
                    hash: stamp.size == entry.size ? try? ContentHash.hexOfFile(at: url) : nil))
        }

        for folder in directories {
            guard let url = destination.url(root: folder.root, path: folder.path) else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
                let path = folder.path.isEmpty ? name : folder.path + "/" + name
                guard seen.insert(key(folder.root, path)).inserted else { continue }
                let stamp = BackupSetResolver.stamp(of: url.appendingPathComponent(name), fm: fm)
                files.append(
                    RestoreLocalFile(
                        root: folder.root, path: path, size: stamp?.size ?? 0, hash: nil))
            }
        }
        return files
    }

    /// One directory under one named root.
    private struct Folder: Hashable {
        var root: EntryRoot
        var path: String
    }

    private static func key(_ root: EntryRoot, _ path: String) -> String {
        root.rawValue + "/" + path
    }

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    /// What the space check of 11.8 measures against.
    private static var freeSpaceBytes: Int64 {
        let values = try? BackupRoot.layout.root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private func log(_ message: String) {
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("RestoreCoordinator", message)
    }
}

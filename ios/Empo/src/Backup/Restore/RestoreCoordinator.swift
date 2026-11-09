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
/// What the fresh-install flow of SPEC 11.4 reads off one target.
struct FreshInstallScan {
    var plan: FreshInstallPlan
    /// The namespaces the adopt question of 11.5 covers.
    var adoptableNamespaceIds: [String]
}

@MainActor
final class RestoreCoordinator {

    static let shared = RestoreCoordinator()

    /// The restore in flight, from its manifest read to its last
    /// file, and the game it writes.
    private var running: (task: Task<RestoreOutcome, Never>, gameKey: String)?

    /// The run gate of 7.6 reads it. A backup that starts now would
    /// snapshot the half-restored tree.
    var isRestoring: Bool { running != nil }

    private init() {}

    // MARK: - The doors, per 11.3

    /// Whether the manual door is open for one game.
    func availability(gameKey: String) -> RestoreAvailability {
        RestorePicker.availability(
            runInFlight: running?.gameKey == gameKey || BackupRunMonitor.shared.isRunning,
            gameIsPlaying: BackupDeviceConditions.isSessionLive)
    }

    /// The fresh-install flow of 11.4, or `nil` where the door of
    /// 11.3 stays closed.
    ///
    /// The door opens once: the user added a first target, the
    /// library is empty, and the target holds device namespaces.
    func freshInstall(
        descriptor: TargetDescriptor, provider: some BackupProvider, targetCount: Int
    ) async -> FreshInstallScan? {
        let scan = RestoreScan(provider: provider, descriptor: descriptor)
        let libraryIsEmpty = GameContainer.discover().isEmpty
        let isFirstTarget = targetCount == 1
        guard libraryIsEmpty, isFirstTarget else { return nil }
        let namespaces: [ScannedNamespace]
        do {
            namespaces = try await scan.namespaces()
        } catch {
            BackupLog.line("RestoreCoordinator", "\(descriptor.label) was not scanned: \(error)")
            return nil
        }

        let preferencesRows = namespaces.flatMap(\.preferencesRows)
        let newestPreferences = RestorePicker.newestFirst(preferencesRows).first
        let buckets =
            namespaces
            .first { $0.id == newestPreferences?.namespaceId }?
            .rescuedSavesBuckets ?? []

        let streamed = BackupTargets.load().filter { $0.id != descriptor.id }
        let plan = FreshInstallMerge.plan(
            gameRows: namespaces.flatMap(\.gameRows),
            preferencesRow: newestPreferences,
            orphanedBuckets: buckets,
            hints: FreshInstallHints.lines(
                streamed: streamed,
                canOpenICloud: await ICloudDriveGate.shared.availability().isReady),
            joinedSyncGroup: SyncStore.state().hasJoined)
        guard
            FreshInstallMerge.opens(
                libraryIsEmpty: libraryIsEmpty, isFirstTarget: isFirstTarget, plan: plan)
        else { return nil }

        let mine: String?
        do {
            mine = try BackupKeychain.namespaceId()
        } catch {
            BackupLog.line("RestoreCoordinator", "The namespace id was not read: \(error)")
            mine = nil
        }
        guard let thisDevice = BackupDevice.id else {
            BackupLog.line("RestoreCoordinator", "No adopt is offered, the device id is not known")
            return FreshInstallScan(plan: plan, adoptableNamespaceIds: [])
        }
        let adoptable = namespaces.filter {
            AdoptQuestion.fires(
                recordedDeviceId: $0.deviceId, thisDeviceId: thisDevice,
                alreadyOwned: $0.id == mine)
        }
        return FreshInstallScan(plan: plan, adoptableNamespaceIds: adoptable.map(\.id))
    }

    /// The container a fresh-install restore writes into.
    ///
    /// This device holds no game yet, so the restore makes the
    /// container the snapshot names and writes into it.
    static func makeTheContainer(folderName: String) -> GameContainer? {
        let container = GameContainer(
            url: GameContainer.rootURL.appendingPathComponent(folderName, isDirectory: true))
        guard (try? container.ensureSubdirs()) != nil else { return nil }
        return container
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
        replacesTheTree: Bool = false,
        resumingInto movedAsideTree: String? = nil
    ) async -> RestoreOutcome {
        let scan = RestoreScan(provider: provider, descriptor: descriptor)
        let path = BackupNamespacePaths(root: descriptor.root, namespaceId: row.namespaceId)
            .manifestPath(stream: Self.stream(of: row), snapshotId: row.snapshotId)
        return await run(
            row, into: container, provider: provider, targetId: descriptor.id,
            root: descriptor.root, scope: scope, replacesTheTree: replacesTheTree,
            movedAsideTree: movedAsideTree
        ) {
            do {
                return try await scan.manifest(at: path)
            } catch {
                BackupLog.line("RestoreCoordinator", "\(path) was not read: \(error)")
                return nil
            }
        }
    }

    /// The import of 12.6. The package answers the provider protocol
    /// itself and carries its own manifest, so nothing scans it and
    /// the engine below runs unchanged.
    func restore(
        _ row: SnapshotRow,
        into container: GameContainer?,
        package: PackageSource,
        scope: RestoreScope,
        replacesTheTree: Bool = false,
        resumingInto movedAsideTree: String? = nil
    ) async -> RestoreOutcome {
        let manifest = package.manifest.stream(Self.stream(of: row).key)?.manifest
        return await run(
            row, into: container, provider: package,
            targetId: PackageSource.targetId(packageId: package.packageId), root: "",
            scope: scope, replacesTheTree: replacesTheTree, movedAsideTree: movedAsideTree
        ) { manifest }
    }

    private func run(
        _ row: SnapshotRow,
        into container: GameContainer?,
        provider: some BackupProvider,
        targetId: String,
        root: String,
        scope: RestoreScope,
        replacesTheTree: Bool,
        movedAsideTree: String?,
        manifest readManifest: @escaping @MainActor () async -> SnapshotManifest?
    ) async -> RestoreOutcome {
        guard running == nil else {
            return .failed(
                String(localized: "Another restore is running. Wait for it to finish, then try again."))
        }
        guard !Task.isCancelled else { return .stopped(.cancelled, RestoreResult()) }
        guard !BackupRunMonitor.shared.isRunning else {
            return .failed(
                String(localized: "A backup is running. Wait for it to finish, then try again."))
        }
        guard !gameLaunches, !BackupDeviceConditions.isSessionLive else {
            return .stopped(.gameLaunched, RestoreResult())
        }

        let task = Task<RestoreOutcome, Never> {
            await prepareAndRun(
                row, into: container, provider: provider, targetId: targetId, root: root,
                scope: scope, replacesTheTree: replacesTheTree, movedAsideTree: movedAsideTree,
                manifest: readManifest)
        }
        // A fresh-install restore has no container yet, so the
        // snapshot names the game.
        let gameKey =
            container.map { BackupKeys.gameKey(containerFolderName: $0.folderName) }
            ?? row.identity.gameKey
        running = (task, gameKey)
        // The downloads ride the background session and survive on
        // their own. The grant covers the hash check and the copy
        // between two of them once the user has left the app.
        // `BackupBackgroundTask` cancels the body when the grant ends,
        // and the restore runs in its own task.
        _ = await withTaskCancellationHandler {
            await BackupBackgroundTask.run(named: "restore") {
                await withTaskCancellationHandler {
                    _ = await task.value
                } onCancel: {
                    task.cancel()
                }
            }
        } onCancel: {
            task.cancel()
        }
        var outcome = await task.value
        running = nil
        // The engine reads any cancel as a game launch. A cancel of the
        // caller's task is a Stop of the user.
        if cancelledByTheUser || Task.isCancelled, case .stopped(.gameLaunched, let result) = outcome {
            outcome = .stopped(.cancelled, result)
        }
        cancelledByTheUser = false
        BackupScheduler.shared.conditionsDidChange()
        BackupLog.debug("RestoreCoordinator", "restore of \(row.snapshotId): \(outcome)")
        return outcome
    }

    private func prepareAndRun(
        _ row: SnapshotRow,
        into container: GameContainer?,
        provider: some BackupProvider,
        targetId: String,
        root: String,
        scope: RestoreScope,
        replacesTheTree: Bool,
        movedAsideTree: String?,
        manifest readManifest: () async -> SnapshotManifest?
    ) async -> RestoreOutcome {
        let manifest = await readManifest()
        guard !Task.isCancelled else { return .stopped(.gameLaunched, RestoreResult()) }
        guard let manifest, manifest.gameKey == row.identity.gameKey else {
            return .failed(RestoreNotices.unreadableLine)
        }
        let destination = Self.destination(for: container, manifest: manifest)
        let localFiles = await Self.localFiles(
            destination: destination, manifest: manifest, scope: scope)
        guard !Task.isCancelled, !gameLaunches, !BackupDeviceConditions.isSessionLive else {
            return .stopped(.gameLaunched, RestoreResult())
        }

        let request = RestoreRequest(
            targetId: targetId,
            root: root,
            namespaceId: row.namespaceId,
            stream: Self.stream(of: row),
            snapshotId: row.snapshotId,
            choice: replacesTheTree ? .replaceTheTree : .restore(scope),
            destination: destination,
            localFiles: localFiles,
            localVersionMarker: container.map(GameIdentities.versionMarker(for:)),
            freeSpaceBytes: BackupRoot.freeSpaceBytes,
            mode: manifest.mode,
            movedAsideTree: movedAsideTree)

        let store: BackupStateStore
        do {
            store = try BackupRoot.openStateStore()
        } catch {
            return .failed(
                String(
                    localized:
                        "Empo couldn't open its records on this device. Close Empo, open it again, then try again."
                ))
        }

        // `EmpoState/` always restores, so the snapshot's alias file
        // replaces this one, the attach of 4.3 included.
        let aliasesBefore = container.map { IdentityAliases.load(from: $0.empoStateURL) }
        let engine = RestoreEngine(provider: provider, store: store, localRoot: BackupRoot.layout.root)
        var outcome = await engine.run(request)
        if let container, let aliasesBefore {
            var aliases = IdentityAliases.load(from: container.empoStateURL)
            if aliases.merge(aliasesBefore, forFolderName: container.folderName) {
                do {
                    try aliases.save(to: container.empoStateURL)
                } catch {
                    BackupLog.line(
                        "RestoreCoordinator",
                        "The aliases of \(container.folderName) were not saved: \(error)")
                }
            }
        }
        // The rollback of 10.9. The stream carries one export file,
        // and applying it is what makes the snapshot the live
        // settings. A Rescued Saves restore leaves that file out.
        if case .finished = outcome, request.stream == .preferences,
            scope.restoresTheSettingsFile(of: manifest),
            !PreferenceRestore.applyTheRestoredFile()
        {
            outcome = .failed(Self.settingsUnchangedLine)
        }
        return outcome
    }

    /// The stream a row belongs to. The preferences stream of 5.3
    /// carries the game key of the empty container name, so one
    /// reading covers both kinds of row.
    private static func stream(of row: SnapshotRow) -> BackupStream {
        BackupStream(key: row.identity.gameKey)
    }

    private static let settingsUnchangedLine =
        String(localized: "Empo restored the backup, but your settings didn't change. Try again.")

    /// From the tap on a game until the session counts as live, no
    /// restore may start.
    private var gameLaunches = false

    /// The hard stop of 7.6. A game launched, so the restore stops at
    /// once and leaves its record and its staged blobs. It returns
    /// when the restore wrote its last file.
    func stopForGameLaunch() async {
        await stop()
        BackupLog.debug("RestoreCoordinator", "a game launched, so the restore stopped")
    }

    /// The Stop of the fresh-install screen. The engine reads any
    /// cancel as a game launch, so the coordinator renames the reason.
    func cancel() async {
        guard running != nil else { return }
        cancelledByTheUser = true
        await stop()
        BackupLog.debug("RestoreCoordinator", "the user stopped the restore")
    }

    private var cancelledByTheUser = false

    private func stop() async {
        guard let task = running?.task else { return }
        task.cancel()
        _ = await task.value
    }

    func gameLaunchBegins() {
        gameLaunches = true
    }

    func gameLaunchEnds() {
        gameLaunches = false
    }

    // MARK: - The resume question, per 11.9

    /// The record the next launch asks about, or `nil` when there is
    /// nothing to ask.
    func pendingResume() -> BackupIntentRecord? {
        do {
            let store = try BackupRoot.openStateStore()
            defer { store.close() }
            let record = try store.intent(kind: .interruptedRestore)
            return RestoreResumeQuestion.asks(record) ? record : nil
        } catch {
            BackupLog.line("RestoreCoordinator", "The resume record was not read: \(error)")
            return nil
        }
    }

    /// Marked when the sheet shows. A kill with the sheet open runs no
    /// `onDisappear`, so the answer is too late to mark it.
    func markResumeAsked() {
        do {
            let store = try BackupRoot.openStateStore()
            defer { store.close() }
            try store.markIntentAsked(kind: .interruptedRestore)
        } catch {
            BackupLog.line("RestoreCoordinator", "The resume ask was not marked: \(error)")
        }
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
            let snapshotId = record.snapshotId,
            case .restore(let choice, let movedAsideTree) = record.work
        else { return .failed(String(localized: "This location isn't set up on this device any more.")) }

        let namespaces: [ScannedNamespace]
        do {
            namespaces = try await RestoreScan(provider: provider, descriptor: descriptor).namespaces()
        } catch {
            BackupLog.line("RestoreCoordinator", "The resume scan of \(descriptor.label) failed: \(error)")
            return .failed(RestoreNotices.unreadableLine)
        }
        guard
            let row = namespaces.flatMap({ $0.gameRows + $0.preferencesRows })
                .first(where: { $0.snapshotId == snapshotId })
        else { return .failed(RestoreNotices.unreadableLine) }

        let container = record.gameKey.flatMap { key in
            GameContainer.discover().first {
                BackupKeys.gameKey(containerFolderName: $0.folderName) == key
            }
        }
        return await restore(
            row, into: container, provider: provider, descriptor: descriptor,
            scope: choice.scope, replacesTheTree: choice == .replaceTheTree,
            resumingInto: movedAsideTree)
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
            case .restore(let choice, let movedAsideTree) = record.work,
            let row = PackageSource.rows(of: source.manifest, packageId: packageId)
                .first(where: { $0.snapshotId == snapshotId })
        else { return .failed(String(localized: "The backup file isn't on this device any more.")) }

        return await restore(
            row, into: GameIdentities.match(row.identity), package: source,
            scope: choice.scope, replacesTheTree: choice == .replaceTheTree,
            resumingInto: movedAsideTree)
    }

    /// Applies one answer. The caller resumes the restore itself when
    /// the effect says to start it now.
    func answerResume(_ action: RestoreResumeQuestion.Action, record: BackupIntentRecord) {
        let effect = RestoreResumeQuestion.effect(of: action)
        guard !effect.keepsRecord else { return }
        do {
            let store = try BackupRoot.openStateStore()
            defer { store.close() }
            try store.clearIntent(kind: .interruptedRestore)
        } catch {
            BackupLog.line("RestoreCoordinator", "The resume record was not cleared: \(error)")
            return
        }
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
        let isPreferences = manifest.gameKey == BackupStream.preferencesKey
        let sharedData: URL? =
            if isPreferences {
                nil
            } else if let container, let core = GameCores.core(forGameAt: container.gameURL) {
                DataDirectory.resolve(for: container, core: core)
            } else {
                // A fresh-install restore makes the container with an empty
                // game, so only the snapshot knows the folder.
                manifest.sharedDataDirectory.flatMap {
                    ExternalMembers.url(ofRecordedPath: $0, documentsRoot: DataDirectory.documentsRootURL)
                }
            }
        return MemberSource(
            container: container?.url,
            sharedData: sharedData,
            rescuedBuckets: RescuedSaves.restorableBuckets(
                named: manifest.rescuedSavesBuckets, in: DataDirectory.rescuedSavesRootURL,
                folderName: isPreferences ? nil : container?.folderName ?? manifest.containerFolderName),
            profiles: isPreferences ? LayoutProfilesManager.profilesRootURL : nil,
            userDefaultsExport: isPreferences ? PreferenceRestore.restoredFile : nil)
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
    /// never hold the same content. A game can hold gigabytes, so the
    /// reads run off the main actor.
    nonisolated static func localFiles(
        destination: MemberSource, manifest: SnapshotManifest, scope: RestoreScope
    ) async -> [RestoreLocalFile] {
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

    nonisolated private static func key(_ root: EntryRoot, _ path: String) -> String {
        root.rawValue + "/" + path
    }

    nonisolated private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }
}

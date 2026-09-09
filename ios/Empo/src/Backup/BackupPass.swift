import Foundation
import GameProbe
import UIKit

/// One backup pass: every enabled target, every game the trigger
/// covers, through the snapshot engine of SPEC 5.
///
/// The scheduler of ticket 007 owns when a pass runs and stops it at
/// every gate. This file owns what a pass carries: it turns the
/// library into a `BackupRunRequest` and hands it to `SnapshotEngine`,
/// which does the rest.
///
/// A game whose mode is still unanswered is skipped, per 3.5. The
/// Backups screen asks about every such game before it starts a run.
@MainActor
final class BackupPass: BackupRunning {

    static let shared = BackupPass()

    private init() {}

    func runBackup(
        scope: BackupScanScope, trigger: BackupTrigger, progress: Progress?
    ) async -> BackupPassResult {
        let targets = BackupTargets.load().filter { !$0.isPaused }
        guard !targets.isEmpty else {
            log("the pass found no target")
            return BackupPassResult(didFinish: true)
        }

        let (games, names) = await gamesInScope(scope)
        BackupRunMonitor.shared.runStarts(
            names: names, progress: progress, targetCount: targets.count)
        var rows: [BackupPassTarget] = []
        var didFinish = true

        for descriptor in targets {
            guard !Task.isCancelled else {
                BackupRunMonitor.shared.runEnds()
                return BackupPassResult(targets: rows)
            }
            // A game wins everything, per 7.6. The session end runs
            // the backbone pass, which takes the rest.
            guard !BackupDeviceConditions.isSessionLive else {
                log("a game is running, the pass stops before \(descriptor.label)")
                BackupRunMonitor.shared.pause = .gameRunning
                didFinish = false
                break
            }
            guard let provider = await BackupTargets.provider(for: descriptor) else {
                // The gate of 9.1 is closed, or the provider is not
                // built yet. Neither is a failure the user can clear,
                // so nothing notifies.
                log("\(descriptor.label) cannot open in this build")
                continue
            }

            let result = await run(descriptor, provider: provider, games: games)
            guard !Task.isCancelled else {
                // A pause. The target row and the notices stay as
                // they were, because the run proved nothing.
                BackupRunMonitor.shared.runEnds()
                return BackupPassResult(didFinish: false, targets: rows)
            }
            BackupRunMonitor.shared.targetEnds()
            guard let result else {
                didFinish = false
                continue
            }
            if result.stop == .gameStarted { BackupRunMonitor.shared.pause = .gameRunning }
            let causes = Self.causes(of: result)
            if result.outcome != .success {
                didFinish = false
                if BackupRunMonitor.shared.stopLine == nil, result.stop != .gameStarted {
                    BackupRunMonitor.shared.stopLine = Self.stopLine(
                        of: result, causes: causes, label: descriptor.label)
                }
            }
            // A run the system cut short proves nothing about the
            // target, so it must not re-arm a notification, per 7.11.
            guard result.outcome == .success || !causes.isEmpty else { continue }
            rows.append(
                BackupPassTarget(id: descriptor.id, label: descriptor.label, causes: causes))
        }

        BackupRunMonitor.shared.runEnds()
        return BackupPassResult(didFinish: didFinish, targets: rows)
    }

    // MARK: - One target

    private func run(
        _ descriptor: TargetDescriptor, provider: some BackupProvider, games: [BackupRunGame]
    ) async -> BackupRunResult? {
        let namespaceId: String
        let store: BackupStateStore
        do {
            namespaceId = try BackupKeychain.namespaceId()
            // One store belongs to the task that opened it, so the
            // engine gets its own.
            store = try BackupStateStore(url: BackupRoot.layout.stateDatabase)
        } catch {
            log("\(descriptor.label) could not open its local state")
            return nil
        }

        var conflicts = WriterConflicts.read(
            applicationSupport: BackupRoot.layout.applicationSupport)
        let answer = conflicts.answer(for: descriptor.id)
        let request = BackupRunRequest(
            runId: UUID().uuidString,
            descriptor: descriptor,
            namespaceId: namespaceId,
            deviceId: BackupDevice.id,
            deviceName: BackupDevice.name,
            deviceModel: BackupDevice.model,
            retentionPreset: BackupSettings.retention,
            freeSpaceBytes: Self.freeSpaceBytes,
            preferences: GameBackupSets.libraryRequest(
                userDefaultsExportFile: DevicePreferences.writeTheExportFile()),
            games: games,
            writerResolution: answer?.resolution,
            splitNamespaceId: answer?.splitNamespaceId,
            syncGroupId: SyncStore.state().groupId)

        // The engine takes the store over. `SQLiteDatabase` closes
        // its handle when the last reference goes, so nothing here
        // may hold it after this line.
        let engine = SnapshotEngine(
            provider: provider, store: store, localRoot: BackupRoot.layout.root,
            observer: BackupRunMonitor.shared,
            note: { BackupLog.line("SnapshotEngine", $0) })
        let result = await engine.run(request)
        log(
            "\(descriptor.label): \(result.outcome), \(result.uploadedBytes) bytes, "
                + "\(result.streams.count) streams"
                + (result.stop.map { ", stop \($0)" } ?? ""))
        conflicts.runEnded(targetId: descriptor.id, stop: result.stop, didSplit: result.didSplit)
        try? conflicts.write(applicationSupport: BackupRoot.layout.applicationSupport)
        if result.didSplit {
            moveTheDevice(to: result.namespaceId, after: descriptor)
        }
        return result
    }

    /// The namespace id is one per device, so a split on one target
    /// moves every target to the new space. The others start from a
    /// full upload on their next run, like the one that split.
    private func moveTheDevice(to namespaceId: String, after descriptor: TargetDescriptor) {
        do {
            try BackupKeychain.adoptNamespaceId(namespaceId)
        } catch {
            log("\(descriptor.label) split to \(namespaceId) but the Keychain kept the old id")
            return
        }
        log("\(descriptor.label) split, the device now writes to \(namespaceId)")
        guard let store = try? BackupStateStore(url: BackupRoot.layout.stateDatabase) else { return }
        defer { store.close() }
        for other in BackupTargets.load() where other.id != descriptor.id {
            try? store.clearNamespaceState(targetId: other.id)
        }
    }

    // MARK: - The games

    /// The games this trigger covers, in the order 7.8 asks for,
    /// with the name each one shows. The pill and the run block of
    /// 13.2 name the game they upload.
    private func gamesInScope(
        _ scope: BackupScanScope
    ) async -> (games: [BackupRunGame], names: [String: String]) {
        let containers = GameContainer.discover()
        let byKey = Dictionary(
            uniqueKeysWithValues: containers.map {
                (BackupKeys.gameKey(containerFolderName: $0.folderName), $0)
            })

        var dirty: [DirtyMark] = []
        var restoring: String?
        if let store = try? BackupStateStore(url: BackupRoot.layout.stateDatabase) {
            dirty = (try? store.dirtyGames()) ?? []
            restoring = (try? store.intent(kind: .interruptedRestore))?.gameKey
            store.close()
        }
        if let restoring, byKey[restoring] != nil {
            log("\(restoring) sits out, its restore has not finished")
        }
        let keys = BackupTriggerPlan.games(
            in: scope, dirty: dirty, library: Array(byKey.keys).sorted(), restoring: restoring)

        let thresholds = BackupTargets.thresholds()
        var games: [BackupRunGame] = []
        var names: [String: String] = [:]
        for key in keys {
            guard let container = byKey[key] else { continue }
            // The legacy per-game keys have to leave UserDefaults
            // before the run stages `EmpoState/`, or the layout goes
            // up in neither place.
            ControlsLayout.migrateLegacyPersistence(container: container)
            let resolution = await GameBackupSets.resolveMode(
                for: container, targets: thresholds)
            guard case .mode(let mode) = resolution else {
                // The ask of 3.5 has no answer yet, so this game
                // waits for it.
                continue
            }
            let metadata = GameMetadata.load(from: container)
            names[key] = BackupGameNames.name(of: container, in: metadata)
            games.append(
                BackupRunGame(
                    identity: GameIdentities.identity(for: container),
                    set: await GameBackupSets.request(for: container, mode: mode),
                    versionMarker: GameIdentities.versionMarker(for: container),
                    lastPlayedAt: metadata.lastPlayed))
        }
        return (games, names)
    }

    // MARK: - The device

    /// What the budget of 6.4 may spend. The engine takes it as an
    /// input, so no rule inside it reads the host.
    private static var freeSpaceBytes: Int64 {
        let values = try? BackupRoot.layout.root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// What the pill says after the run, per 13.2. The target row
    /// names the stop, so the pill uses the same words.
    private static func stopLine(
        of result: BackupRunResult, causes: Set<BackupFailFastCause>, label: String
    ) -> String {
        let device = BackupDeviceConditions.deviceName
        if case .writerConflict = result.stop {
            return WriterConflictQuestion.stopLine(targetLabel: label)
        }
        if let cause = StaleCause.of(result.stop.flatMap(TargetFailure.of)) {
            return cause.line(targetLabel: label, deviceName: device)
        }
        guard let cause = BackupFailFastCause.allCases.first(where: causes.contains) else {
            return "\(label) did not finish"
        }
        return cause.staleCause.line(targetLabel: label, deviceName: device)
    }

    private static func causes(of result: BackupRunResult) -> Set<BackupFailFastCause> {
        var causes: Set<BackupFailFastCause> = []
        if let cause = result.stop.flatMap(BackupNotificationRule.failFastCause) {
            causes.insert(cause)
        }
        for stream in result.streams {
            if let cause = BackupNotificationRule.failFastCause(of: stream.outcome) {
                causes.insert(cause)
            }
        }
        return causes
    }

    private func log(_ message: String) {
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("BackupPass", message)
    }
}

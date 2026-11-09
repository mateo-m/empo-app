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
final class BackupPass {

    static let shared = BackupPass()

    private init() {}

    /// `progress` belongs to a continued-processing task, which must
    /// report progress or the system expires it.
    func runBackup(
        scope: BackupScanScope, trigger: BackupTrigger, progress: Progress?
    ) async -> BackupPassResult {
        await EmpoPlus.shared.refresh()
        let targets = BackupTargets.writable()
        guard !targets.isEmpty else {
            BackupLog.debug("BackupPass", "the pass found no target")
            return BackupPassResult(didFinish: true)
        }

        let (games, names) = await gamesInScope(scope, targetIds: Set(targets.map(\.id)))
        BackupGameNames.remember(names)
        BackupRunMonitor.shared.runCovers(
            names: names, progress: progress, targetCount: targets.count)
        var rows: [BackupPassTarget] = []
        var didFinish = true
        var stopNeedsTheUser = false

        for descriptor in targets {
            guard !Task.isCancelled else { return BackupPassResult(targets: rows) }
            // A game wins everything, per 7.6. The session end runs
            // the backbone pass, which takes the rest.
            guard !BackupDeviceConditions.isSessionLive else {
                BackupLog.debug("BackupPass", "a game is running, the pass stops before \(descriptor.label)")
                BackupRunMonitor.shared.pause = .gameRunning
                didFinish = false
                break
            }
            guard let provider = await BackupTargets.provider(for: descriptor) else {
                // The gate of 9.1 is closed, or the provider is not
                // built yet. Neither is a failure the user can clear,
                // so nothing notifies.
                BackupLog.debug("BackupPass", "\(descriptor.label) cannot open in this build")
                BackupRunMonitor.shared.targetEnds()
                continue
            }

            let result = await run(
                descriptor, provider: provider, games: games, trigger: trigger)
            guard !Task.isCancelled else {
                // A pause. The target row and the notices stay as
                // they were, because the run proved nothing.
                return BackupPassResult(didFinish: false, targets: rows)
            }
            BackupRunMonitor.shared.targetEnds()
            guard let result else {
                didFinish = false
                if BackupRunMonitor.shared.stopLine == nil {
                    BackupRunMonitor.shared.stopLine = String(
                        localized: "\(descriptor.displayName) didn't finish.")
                }
                continue
            }
            if result.stop == .gameStarted { BackupRunMonitor.shared.pause = .gameRunning }
            let causes = Self.causes(of: result)
            if result.outcome != .success {
                didFinish = false
                // A stop that only the user can clear replaces one
                // that clears by itself.
                let needsTheUser = !causes.isEmpty
                if result.stop != .gameStarted,
                    BackupRunMonitor.shared.stopLine == nil || (needsTheUser && !stopNeedsTheUser)
                {
                    BackupRunMonitor.shared.stopLine = Self.stopLine(
                        of: result, causes: causes, label: descriptor.displayName)
                    stopNeedsTheUser = needsTheUser
                }
            }
            // A run the system cut short proves nothing about the
            // target, so it must not re-arm a notification, per 7.11.
            guard result.outcome == .success || !causes.isEmpty else { continue }
            rows.append(
                BackupPassTarget(id: descriptor.id, label: descriptor.displayName, causes: causes))
        }

        return BackupPassResult(didFinish: didFinish, targets: rows)
    }

    // MARK: - One target

    private func run(
        _ descriptor: TargetDescriptor, provider: some BackupProvider, games: [BackupRunGame],
        trigger: BackupTrigger
    ) async -> BackupRunResult? {
        guard let deviceId = BackupDevice.id else {
            BackupLog.line("BackupPass", "\(descriptor.label) waits, the device id is not known")
            return nil
        }
        let namespaceId: String
        let store: BackupStateStore
        do {
            namespaceId = try BackupKeychain.namespaceId()
            // One store belongs to the task that opened it, so the
            // engine gets its own.
            store = try BackupRoot.openStateStore()
        } catch {
            BackupLog.line("BackupPass", "\(descriptor.label) could not open its local state: \(error)")
            return nil
        }
        do {
            try BackupNamespaceMove.clearIfWaiting(targetId: descriptor.id, store: store)
        } catch {
            BackupLog.line(
                "BackupPass", "\(descriptor.label) still holds the rows of the old namespace: \(error)")
            return nil
        }
        do {
            try await BackupLedgerRebuild.runIfWaiting(
                descriptor, provider: provider, namespaceId: namespaceId, store: store)
        } catch {
            // The run still goes. A short ledger only keeps old
            // snapshots longer, and the next run tries the rebuild again.
            BackupLog.line("BackupPass", "\(descriptor.label) ledger rebuild failed: \(error)")
        }

        var conflicts = WriterConflicts.read(
            applicationSupport: BackupRoot.layout.applicationSupport)
        let request = BackupRunRequest(
            runId: UUID().uuidString,
            trigger: trigger,
            descriptor: descriptor,
            namespaceId: namespaceId,
            deviceId: deviceId,
            deviceName: BackupDevice.name,
            deviceModel: BackupDevice.model,
            retentionPreset: BackupSettings.retention,
            freeSpaceBytes: BackupRoot.freeSpaceBytes,
            preferences: GameBackupSets.libraryRequest(
                userDefaultsExportFile: DevicePreferences.writeTheExportFile()),
            games: games,
            writerAnswer: conflicts.answer(for: descriptor.id),
            syncGroupId: SyncStore.state().groupId)

        // The engine takes the store over. `SQLiteDatabase` closes
        // its handle when the last reference goes, so nothing here
        // may hold it after this line.
        let engine = SnapshotEngine(
            provider: provider, store: store, localRoot: BackupRoot.layout.root,
            observer: BackupRunMonitor.shared,
            note: { BackupLog.line("SnapshotEngine", $0) })
        BackupRunMonitor.shared.liveRunId = request.runId
        let result = await engine.run(request)
        BackupRunMonitor.shared.liveRunId = nil
        BackupLog.debug(
            "BackupPass",
            "\(descriptor.label): \(result.outcome), \(result.uploadedBytes) bytes, "
                + "\(result.streams.count) streams"
                + (result.stop.map { ", stop \($0)" } ?? ""))
        conflicts.runEnded(targetId: descriptor.id, stop: result.stop, didSplit: result.didSplit)
        do {
            try conflicts.write(applicationSupport: BackupRoot.layout.applicationSupport)
        } catch {
            BackupLog.line("BackupPass", "\(descriptor.label) writer answers were not saved: \(error)")
        }
        if result.didSplit {
            do {
                try BackupNamespaceMove.move(to: result.namespaceId, except: descriptor.id)
                BackupLog.debug(
                    "BackupPass", "\(descriptor.label) split, the device now writes to \(result.namespaceId)")
            } catch {
                BackupLog.line(
                    "BackupPass",
                    "\(descriptor.label) split to \(result.namespaceId) but the Keychain kept the old id")
            }
        }
        return result
    }

    // MARK: - The games

    /// The games this trigger covers, in the order 7.8 asks for,
    /// with the name each one shows. The pill and the run block of
    /// 13.2 name the game they upload.
    private func gamesInScope(
        _ scope: BackupScanScope, targetIds: Set<String>
    ) async -> (games: [BackupRunGame], names: [String: String]) {
        let containers = GameContainer.discover()
        let byKey = Dictionary(
            uniqueKeysWithValues: containers.map {
                (BackupKeys.gameKey(containerFolderName: $0.folderName), $0)
            })

        let dirty: [DirtyMark]
        let restoring: String?
        do {
            let store = try BackupRoot.openStateStore()
            defer { store.close() }
            dirty = try store.dirtyGames()
            restoring = try store.intent(kind: .interruptedRestore)?.gameKey
        } catch {
            BackupLog.line("BackupPass", "No game is backed up, the records were not read: \(error)")
            return ([], [:])
        }
        if let restoring, byKey[restoring] != nil {
            BackupLog.debug("BackupPass", "\(restoring) sits out, its restore has not finished")
        }
        let keys = BackupTriggerPlan.games(
            in: scope, dirty: dirty, library: Array(byKey.keys).sorted(), targetIds: targetIds,
            restoring: restoring)

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
            let name = BackupGameNames.name(of: container, in: metadata)
            names[key] = name
            games.append(
                BackupRunGame(
                    identity: GameIdentities.identity(for: container),
                    title: name,
                    set: await GameBackupSets.request(for: container, mode: mode),
                    versionMarker: GameIdentities.versionMarker(for: container),
                    lastPlayedAt: metadata.lastPlayed))
        }
        return (games, names)
    }

    // MARK: - The device

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
            return result.stop.flatMap { ProgressPill.stopReason(of: $0, targetLabel: label) }
                ?? String(localized: "\(label) didn't finish.")
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
}

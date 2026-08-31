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
/// A game whose mode is still unanswered is skipped, per 3.5. Ticket
/// 017 brings the ask, and ticket 016 brings the screen that starts
/// it.
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

        let games = await gamesInScope(scope)
        progress?.totalUnitCount = Int64(max(1, targets.count))
        var rows: [BackupPassTarget] = []
        var didFinish = true

        for (index, descriptor) in targets.enumerated() {
            guard !Task.isCancelled else { return BackupPassResult(targets: rows) }
            guard let provider = await BackupTargets.provider(for: descriptor) else {
                // The gate of 9.1 is closed, or the provider is not
                // built yet. Neither is a failure the user can clear,
                // so nothing notifies.
                log("\(descriptor.label) cannot open in this build")
                continue
            }

            let result = await run(descriptor, provider: provider, games: games)
            progress?.completedUnitCount = Int64(index + 1)
            guard let result else {
                didFinish = false
                continue
            }
            if result.outcome != .success { didFinish = false }
            rows.append(
                BackupPassTarget(
                    id: descriptor.id, label: descriptor.label,
                    causes: Self.causes(of: result)))
        }

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
            store = try BackupStateStore(url: BackupRoot.stateDatabase)
        } catch {
            log("\(descriptor.label) could not open its local state")
            return nil
        }

        let request = BackupRunRequest(
            runId: UUID().uuidString,
            descriptor: descriptor,
            namespaceId: namespaceId,
            deviceId: Self.deviceId,
            deviceName: UIDevice.current.name,
            deviceModel: UIDevice.current.model,
            retentionPreset: BackupSettings.retention,
            freeSpaceBytes: Self.freeSpaceBytes,
            preferences: GameBackupSets.libraryRequest(),
            games: games)

        // The engine takes the store over. `SQLiteDatabase` closes
        // its handle when the last reference goes, so nothing here
        // may hold it after this line.
        let engine = SnapshotEngine(
            provider: provider, store: store, localRoot: BackupRoot.url)
        let result = await engine.run(request)
        log(
            "\(descriptor.label): \(result.outcome), \(result.uploadedBytes) bytes, "
                + "\(result.streams.count) streams"
                + (result.stop.map { ", stop \($0)" } ?? ""))
        return result
    }

    // MARK: - The games

    /// The games this trigger covers, in the order 7.8 asks for.
    private func gamesInScope(_ scope: BackupScanScope) async -> [BackupRunGame] {
        let containers = GameContainer.discover()
        let byKey = Dictionary(
            uniqueKeysWithValues: containers.map {
                (BackupKeys.gameKey(containerFolderName: $0.folderName), $0)
            })

        var dirty: [DirtyMark] = []
        if let store = try? BackupStateStore(url: BackupRoot.stateDatabase) {
            dirty = (try? store.dirtyGames()) ?? []
            store.close()
        }
        let keys = BackupTriggerPlan.games(
            in: scope, dirty: dirty, library: Array(byKey.keys).sorted())

        let thresholds = BackupTargets.thresholds()
        var games: [BackupRunGame] = []
        for key in keys {
            guard let container = byKey[key] else { continue }
            let resolution = await GameBackupSets.resolveMode(
                for: container, targets: thresholds)
            guard case .mode(let mode) = resolution else {
                // The ask of 3.5 has no answer yet, so this game
                // waits for it. Ticket 017 asks.
                continue
            }
            let metadata = GameMetadata.load(from: container)
            games.append(
                BackupRunGame(
                    identity: GameIdentities.identity(for: container),
                    set: GameBackupSets.request(for: container, mode: mode),
                    versionMarker: GameIdentities.versionMarker(for: container),
                    lastPlayedAt: metadata.lastPlayed))
        }
        return games
    }

    // MARK: - The device

    private static var deviceId: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }

    /// What the budget of 6.4 may spend. The engine takes it as an
    /// input, so no rule inside it reads the host.
    private static var freeSpaceBytes: Int64 {
        let values = try? BackupRoot.url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// The three causes of 7.11 this run carries. Everything else is
    /// transient and feeds only the stale line.
    private static func causes(of result: BackupRunResult) -> Set<BackupFailFastCause> {
        var causes: Set<BackupFailFastCause> = []
        switch result.stop {
        case .needsSignIn:
            causes.insert(.signInDead)
        case .blocked, .full, .quotaShortfall:
            causes.insert(.targetBlocked)
        case .none, .writerConflict, .readOnlyFormat, .offline, .rejected:
            break
        }
        if result.streams.contains(where: { $0.outcome == .notEnoughLocalSpace }) {
            causes.insert(.deviceStorageLow)
        }
        return causes
    }

    private func log(_ message: String) {
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("BackupPass", message)
    }
}

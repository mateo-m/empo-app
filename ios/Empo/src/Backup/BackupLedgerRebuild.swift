import Foundation
import GameProbe

/// With an empty snapshot ledger, the prune keeps every old snapshot
/// and "delete backups" deletes no manifest.
@MainActor
enum BackupLedgerRebuild {

    private static let waiting = BackupTargetWaitList(fileName: "ledger-rebuild.json")

    static func markEveryTarget() {
        do {
            try waiting.add(Set(BackupTargets.load().map(\.id)))
        } catch {
            BackupLog.line("BackupLedgerRebuild", "The rebuild was not marked: \(error)")
        }
    }

    /// Records each manifest of this device on the target. When it
    /// throws, the target stays on the list for the next run.
    static func runIfWaiting(
        _ descriptor: TargetDescriptor, provider: some BackupProvider, namespaceId: String,
        store: BackupStateStore
    ) async throws {
        guard try waiting.ids().contains(descriptor.id) else { return }

        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: namespaceId)
        let streams = [
            (prefix: paths.gamesPrefix + "/", isGames: true),
            (prefix: paths.preferencesPrefix + "/", isGames: false),
        ]
        var count = 0
        for stream in streams {
            for object in try await provider.list(prefix: stream.prefix) {
                guard object.path.hasPrefix(stream.prefix),
                    let snapshotId = BackupNamespacePaths.snapshotId(ofManifestPath: object.path),
                    let createdAt = BackupKeys.timestamp(ofSnapshotId: snapshotId)
                else { continue }
                let parts = object.path.dropFirst(stream.prefix.count).split(separator: "/")
                let gameKey: String
                switch (stream.isGames, parts.count) {
                case (true, 2): gameKey = String(parts[0])
                case (false, 1): gameKey = BackupStream.preferencesKey
                default: continue
                }
                try store.recordSnapshot(
                    SnapshotLedgerEntry(
                        targetId: descriptor.id, gameKey: gameKey, snapshotId: snapshotId,
                        createdAt: createdAt))
                count += 1
            }
        }

        try waiting.remove(descriptor.id)
        BackupLog.line("BackupLedgerRebuild", "\(descriptor.label): \(count) snapshots recorded")
    }
}

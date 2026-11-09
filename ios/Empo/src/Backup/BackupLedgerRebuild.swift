import Foundation
import GameProbe

/// With an empty snapshot ledger, the prune keeps every old snapshot
/// and "delete backups" deletes no manifest. A target can be offline
/// when the store starts empty, so the file keeps the targets that
/// still wait.
@MainActor
enum BackupLedgerRebuild {

    private static var fileURL: URL {
        BackupRoot.layout.root.appendingPathComponent("ledger-rebuild.json")
    }

    static func markEveryTarget() {
        do {
            let ids = Set(BackupTargets.load().map(\.id))
            guard !ids.isEmpty else { return }
            try write(ids.union(try waiting()))
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
        var left = try waiting()
        guard left.contains(descriptor.id) else { return }

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

        left = try waiting()
        left.remove(descriptor.id)
        try write(left)
        BackupLog.line("BackupLedgerRebuild", "\(descriptor.label): \(count) snapshots recorded")
    }

    private static func waiting() throws -> Set<String> {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return try JSONDecoder().decode(Set<String>.self, from: data)
    }

    private static func write(_ ids: Set<String>) throws {
        guard !ids.isEmpty else {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch CocoaError.fileNoSuchFile {}
            return
        }
        try JSONEncoder().encode(ids.sorted()).write(to: fileURL, options: .atomic)
    }
}

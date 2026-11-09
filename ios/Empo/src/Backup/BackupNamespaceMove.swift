import Foundation
import GameProbe

/// The device has one namespace id, so a move sends every target to the
/// new space. The rows of the old space tell the engine that a blob is
/// already up, and the new space does not hold it.
@MainActor
enum BackupNamespaceMove {

    /// After a damaged file, targets that kept their namespace lose their
    /// rows too, so each one rebuilds its snapshot list.
    private static let waiting = BackupTargetWaitList(
        fileName: "namespace-clear.json", afterDamage: BackupLedgerRebuild.markEveryTarget)

    /// `except` is the target whose run made the move. Its engine
    /// cleared its own rows.
    static func move(to namespaceId: String, except: String? = nil) throws {
        try BackupKeychain.adoptNamespaceId(namespaceId)
        var left = Set(BackupTargets.load().map(\.id))
        if let except { left.remove(except) }
        if let store = try? BackupRoot.openStateStore() {
            defer { store.close() }
            for targetId in left {
                do {
                    try store.clearNamespaceState(targetId: targetId)
                    left.remove(targetId)
                } catch {
                    BackupLog.line("BackupNamespaceMove", "\(targetId) kept the old rows: \(error)")
                }
            }
        }
        do {
            try waiting.add(left)
        } catch {
            BackupLog.line("BackupNamespaceMove", "The clear was not marked for \(left): \(error)")
        }
    }

    /// When it throws, the run must stop, because the old rows skip
    /// uploads.
    static func clearIfWaiting(targetId: String, store: BackupStateStore) throws {
        guard try waiting.ids().contains(targetId) else { return }
        try store.clearNamespaceState(targetId: targetId)
        try waiting.remove(targetId)
    }
}

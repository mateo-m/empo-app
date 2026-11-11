import Foundation
import GameProbe

/// The device has one namespace id, so a move sends every target to the
/// new space. The rows of the old space tell the engine that a blob is
/// already up, and the new space does not hold it.
@MainActor
enum BackupNamespaceMove {

    /// Clearing the rows clears the snapshot list too, so each target
    /// that clears also rebuilds its list.
    private static let waiting = BackupTargetWaitList(
        fileName: "namespace-clear.json", afterDamage: BackupLedgerRebuild.mark)

    /// `except` is the target whose run made the move. Its engine
    /// cleared its own rows.
    static func move(to namespaceId: String, except: String? = nil) throws {
        var targets = Set(try BackupTargets.read().map(\.id))
        if let except { targets.remove(except) }
        // The lists go first, so a target whose rows do not clear below
        // still clears and rebuilds before its next run.
        try BackupLedgerRebuild.mark(targets)
        try waiting.add(targets)
        try BackupKeychain.adoptNamespaceId(namespaceId)
        guard let store = try? BackupRoot.openStateStore() else { return }
        defer { store.close() }
        for targetId in targets {
            do {
                try store.clearNamespaceState(targetId: targetId)
                try waiting.remove(targetId)
            } catch {
                BackupLog.line(
                    "BackupNamespaceMove", "\(targetId) clears its old rows at its next run: \(error)")
            }
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

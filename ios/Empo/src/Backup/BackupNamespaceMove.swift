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

    /// A pass in flight writes rows of the old namespace after they
    /// clear, so no pass runs during the move.
    static func adopt(_ namespaceId: String) async throws {
        try await BackupScheduler.shared.withRunsHeld { Result { try move(to: namespaceId) } }.get()
    }

    /// A failed move keeps the old namespace, while the rows of the
    /// split target already name the new one. So that target clears
    /// and rebuilds before its next run.
    static func afterSplit(to namespaceId: String, targetId: String) throws {
        do {
            try move(to: namespaceId, except: targetId)
        } catch {
            try BackupLedgerRebuild.mark([targetId])
            try waiting.add([targetId])
            throw error
        }
    }

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

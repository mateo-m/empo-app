import Foundation
import GameProbe

/// The preference rollback and its undo, per SPEC 10.9.
///
/// A restore of the `prefs/` stream lands as a file. This applies
/// that file to UserDefaults, and on a joined device the next
/// replication pass carries it to the group as new changes. Nothing
/// here rewinds the document.
@MainActor
enum PreferenceRestore {

    /// Where a restore of the preferences stream puts the export
    /// before Empo applies it. A finished restore empties `restore/`
    /// before Empo applies the file, so the file sits outside it.
    static var restoredFile: URL {
        BackupRoot.layout.root.appendingPathComponent(
            PreferencesMemberPath.userDefaultsExportName)
    }

    /// What the confirmation says. On a joined device the change
    /// reaches every device of the group, per 10.9.
    static var confirmation: String {
        let line = GameProbe.PreferenceRestore.confirmationLine
        return SyncStore.state().hasJoined ? line + " " + PreferenceRollback.confirmation : line
    }

    static func applyTheRestoredFile(at date: Date = Date()) -> Bool {
        defer { try? FileManager.default.removeItem(at: restoredFile) }
        guard let data = try? Data(contentsOf: restoredFile),
            let document = try? PreferenceExport.decode(json: data)
        else { return false }

        let current = DevicePreferences.currentDefaults()
        let plan = PreferenceRollback.plan(current: current, snapshot: document.values)
        guard !plan.isEmpty else { return true }

        // The undo holds what the user had before, so it goes in
        // before the first key moves. With no undo, nothing moves.
        do {
            try PreferenceRollbackUndo(
                savedAt: date, values: PreferenceExport.portableValues(of: current)
            ).write(applicationSupport: BackupRoot.layout.applicationSupport)
        } catch {
            return false
        }

        do {
            try apply(plan)
        } catch {
            PreferenceRollbackUndo.clear(applicationSupport: BackupRoot.layout.applicationSupport)
            return false
        }
        return true
    }

    /// The one undo of 10.9. It expires after 7 days, and reading it
    /// after that drops it.
    static func undo(at date: Date = Date()) -> Bool {
        guard
            let undo = PreferenceRollbackUndo.read(
                applicationSupport: BackupRoot.layout.applicationSupport, at: date)
        else { return false }
        do {
            try apply(
                PreferenceRollback.plan(
                    current: DevicePreferences.currentDefaults(), snapshot: undo.values))
        } catch {
            return false
        }
        PreferenceRollbackUndo.clear(applicationSupport: BackupRoot.layout.applicationSupport)
        return true
    }

    static func hasUndo(at date: Date = Date()) -> Bool {
        PreferenceRollbackUndo.read(
            applicationSupport: BackupRoot.layout.applicationSupport, at: date) != nil
    }

    /// A removal the sync state did not record comes back from the
    /// group on the next pass, so nothing changes without it.
    private static func apply(_ plan: PreferenceRollbackPlan) throws {
        if SyncStore.state().hasJoined, !plan.deletes.isEmpty {
            try SyncStore.update {
                $0.removedPreferenceKeys = Array(Set($0.removedPreferenceKeys).union(plan.deletes))
                    .sorted()
            }
        }
        DevicePreferences.apply(plan.sets)
        DevicePreferences.remove(plan.deletes)
        SyncPass.shared.schedule(.now)
    }
}

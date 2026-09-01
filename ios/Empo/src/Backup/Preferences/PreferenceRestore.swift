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
    /// before Empo applies it.
    static var restoredFile: URL {
        BackupRoot.layout.restore.appendingPathComponent(BackupSetResolver.userDefaultsExportPathName)
    }

    /// What the confirmation says. On a joined device the change
    /// reaches every device of the group, per 10.9.
    static var confirmation: String? {
        SyncStore.state().hasJoined ? PreferenceRollback.confirmation : nil
    }

    /// Applies the file a restore just wrote.
    @discardableResult
    static func applyTheRestoredFile(at date: Date = Date()) -> Bool {
        defer { try? FileManager.default.removeItem(at: restoredFile) }
        guard let data = try? Data(contentsOf: restoredFile),
            let document = try? PreferenceExport.decode(json: data)
        else { return false }

        let current = DevicePreferences.currentDefaults()
        let plan = PreferenceRollback.plan(current: current, snapshot: document.values)
        guard !plan.isEmpty else { return true }

        // The undo holds what the user had before, so it goes in
        // before the first key moves.
        try? PreferenceRollbackUndo(
            savedAt: date, values: PreferenceExport.portableValues(of: current)
        ).write(applicationSupport: BackupRoot.layout.applicationSupport)

        apply(plan)
        return true
    }

    /// The one undo of 10.9. It expires after 7 days, and reading it
    /// after that drops it.
    static func undo(at date: Date = Date()) -> Bool {
        guard
            let undo = PreferenceRollbackUndo.read(
                applicationSupport: BackupRoot.layout.applicationSupport, at: date)
        else { return false }
        apply(
            PreferenceRollback.plan(
                current: DevicePreferences.currentDefaults(), snapshot: undo.values))
        PreferenceRollbackUndo.clear(applicationSupport: BackupRoot.layout.applicationSupport)
        return true
    }

    static func hasUndo(at date: Date = Date()) -> Bool {
        PreferenceRollbackUndo.read(
            applicationSupport: BackupRoot.layout.applicationSupport, at: date) != nil
    }

    private static func apply(_ plan: PreferenceRollbackPlan) {
        DevicePreferences.apply(plan.sets)
        DevicePreferences.remove(plan.deletes)
        SyncPass.shared.schedule(after: 0)
    }
}

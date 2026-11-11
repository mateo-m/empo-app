import Foundation
import GameProbe

/// `BackupRootLayout` in GameProbe holds the names and the URLs, so
/// `swift test` reaches them.
enum BackupRoot {

    static var layout: BackupRootLayout {
        BackupRootLayout(
            applicationSupport: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    @discardableResult
    static func prepare() -> Bool {
        do {
            try layout.createDirectories()
        } catch {
            BackupLog.line("BackupRoot", "The backup directories were not made: \(error)")
            return false
        }
        excludeFromDeviceBackup()
        return true
    }

    /// iOS carries the flag to the contents of the directory. The root
    /// holds only copies and a cache, so the device backup must not
    /// spend the iCloud quota on it a second time.
    private static func excludeFromDeviceBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = layout.root
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            BackupLog.line("BackupRoot", "The root stays in the device backup: \(error)")
        }
    }

    /// 0 when the read fails, so the space checks stop the work instead
    /// of filling the disk.
    static var freeSpaceBytes: Int64 {
        do {
            let values = try layout.root.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            BackupLog.line("BackupRoot", "The free space was not read: \(error)")
            return 0
        }
    }

    /// The caller can then write a new file, and each damaged copy stays
    /// on the device.
    static func setAside(_ file: URL, caller: String = #fileID) throws {
        let aside = asideURL(of: file)
        try FileManager.default.moveItem(at: file, to: aside)
        BackupLog.line(
            caller, "\(file.lastPathComponent) did not read, so it moved to \(aside.lastPathComponent)")
    }

    /// For a file that must stay until its replacement is saved.
    static func copyAside(_ file: URL, caller: String = #fileID) throws {
        let aside = asideURL(of: file)
        try FileManager.default.copyItem(at: file, to: aside)
        BackupLog.line(
            caller, "\(file.lastPathComponent) did not read, so it was copied to \(aside.lastPathComponent)")
    }

    private static func asideURL(of file: URL) -> URL {
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        return file.deletingPathExtension().appendingPathExtension("damaged-\(stamp).json")
    }

    static func writerConflicts(caller: String = #fileID) throws -> WriterConflicts {
        let applicationSupport = layout.applicationSupport
        do {
            return try WriterConflicts.read(applicationSupport: applicationSupport)
        } catch is DecodingError {
            try setAside(
                applicationSupport.appendingPathComponent(WriterConflicts.fileName), caller: caller)
            return WriterConflicts()
        }
    }

    @MainActor
    static func openStateStore(
        at url: URL = layout.stateDatabase, caller: String = #fileID
    ) throws -> BackupStateStore {
        let store: BackupStateStore
        do {
            store = try BackupStateStore(url: url)
        } catch {
            BackupLog.line(caller, "The backup records were not opened: \(error)")
            throw error
        }
        if store.needsRebuildFromTarget {
            BackupLog.line(caller, "The backup records start empty: \(store.openOutcome)")
            do {
                try BackupLedgerRebuild.markEveryTarget()
            } catch {
                // The next open of this file reads as `.opened` and marks nothing. The store holds
                // no rows yet, so it goes, and the next open makes it again and marks again.
                store.close()
                BackupStateStore.removeDatabaseFiles(at: url)
                BackupLog.line(caller, "The rebuild was not marked, so the backup records go: \(error)")
                throw error
            }
        }
        return store
    }
}

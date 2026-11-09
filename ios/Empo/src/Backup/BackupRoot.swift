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

    /// A settings file that does not decode moves to
    /// `<name>.damaged.json`, so the caller can write a new file and the
    /// old bytes stay on the device.
    static func setAside(_ file: URL, caller: String = #fileID) throws {
        let aside = file.deletingPathExtension().appendingPathExtension("damaged.json")
        let manager = FileManager.default
        if manager.fileExists(atPath: aside.path) {
            try manager.removeItem(at: aside)
        }
        try manager.moveItem(at: file, to: aside)
        BackupLog.line(
            caller, "\(file.lastPathComponent) did not read, so it moved to \(aside.lastPathComponent)")
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
    static func openStateStore(caller: String = #fileID) throws -> BackupStateStore {
        let store: BackupStateStore
        do {
            store = try BackupStateStore(url: layout.stateDatabase)
        } catch {
            BackupLog.line(caller, "The backup records were not opened: \(error)")
            throw error
        }
        if store.needsRebuildFromTarget {
            BackupLog.line(caller, "The backup records start empty: \(store.openOutcome)")
            BackupLedgerRebuild.markEveryTarget()
        }
        return store
    }
}

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

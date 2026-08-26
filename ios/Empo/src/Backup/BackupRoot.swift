import Foundation
import GameProbe

/// The local backup root on this device, per SPEC 6.1.
///
/// `BackupRootLayout` in GameProbe holds the names and the URLs, so
/// `swift test` reaches them. This type owns the two things only iOS
/// can do: it makes the directories, and it keeps the root out of the
/// device backup.
enum BackupRoot {

    /// `Library/Application Support/`. The root sits inside it, and
    /// `targets.json` and the preference rollback undo sit beside it.
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var url: URL {
        BackupRootLayout.root(inApplicationSupport: applicationSupport)
    }

    static var stateDatabase: URL {
        BackupRootLayout.stateDatabase(root: url)
    }

    static var staging: URL {
        BackupRootLayout.staging(root: url)
    }

    static var outbox: URL {
        BackupRootLayout.outbox(root: url)
    }

    static var restore: URL {
        BackupRootLayout.restore(root: url)
    }

    /// The target descriptors of 8.8. Section 8 owns the contents.
    static var targetsFile: URL {
        BackupRootLayout.targetsFile(applicationSupport: applicationSupport)
    }

    /// The preference rollback undo of 10.9. Section 10 owns the
    /// contents.
    static var preferenceRollbackFile: URL {
        BackupRootLayout.preferenceRollbackFile(applicationSupport: applicationSupport)
    }

    /// Makes the root and its three directories, then excludes the
    /// root from the device backup. Safe to call on every launch.
    @discardableResult
    static func prepare() -> Bool {
        do {
            try BackupRootLayout.createDirectories(root: url)
        } catch {
            return false
        }
        excludeFromDeviceBackup()
        return true
    }

    /// Sets `NSURLIsExcludedFromBackupKey` on the root, the way
    /// `GameContainer.excludeFromBackup()` does. iOS carries the flag
    /// to the directory's contents.
    ///
    /// The root holds a cache, staged copies, and blobs already on a
    /// target. Every byte of it is either rebuildable or a duplicate,
    /// so putting it in the device backup would spend the user's
    /// iCloud quota twice on the same saves.
    static func excludeFromDeviceBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    /// Opens the state store, per 6.2. A caller that sees
    /// `needsRebuildFromTarget` downloads the newest manifest and
    /// rebuilds from it, per 6.3.
    static func openStateStore() throws -> BackupStateStore {
        try BackupStateStore(url: stateDatabase)
    }

    /// Deletes the whole root. The cache is never truth, per 6.3, so
    /// this costs CPU and not bytes. `targets.json` and the
    /// preference undo sit beside the root and stay.
    static func deleteAll() throws {
        try FileManager.default.removeItem(at: url)
    }
}

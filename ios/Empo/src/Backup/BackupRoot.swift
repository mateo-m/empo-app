import Foundation
import GameProbe

/// The local backup root on this device, per SPEC 6.1.
///
/// `BackupRootLayout` in GameProbe holds the names and the URLs, so
/// `swift test` reaches them. This type owns the two things only iOS
/// can do: it makes the directories, and it keeps the root out of the
/// device backup.
enum BackupRoot {

    /// Every path of 6.1, from this device's Application Support.
    static var layout: BackupRootLayout {
        BackupRootLayout(
            applicationSupport: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// Makes the root and its three directories, then excludes the
    /// root from the device backup. Safe to call on every launch.
    @discardableResult
    static func prepare() -> Bool {
        do {
            try layout.createDirectories()
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
        var mutableURL = layout.root
        try? mutableURL.setResourceValues(values)
    }

    /// Opens the state store, per 6.2. A caller that sees
    /// `needsRebuildFromTarget` downloads the newest manifest and
    /// rebuilds from it, per 6.3.
    static func openStateStore() throws -> BackupStateStore {
        try BackupStateStore(url: layout.stateDatabase)
    }

    /// Deletes the whole root. The cache is never truth, per 6.3, so
    /// this costs CPU and not bytes. `targets.json` and the
    /// preference undo sit beside the root and stay.
    static func deleteAll() throws {
        try FileManager.default.removeItem(at: layout.root)
    }
}

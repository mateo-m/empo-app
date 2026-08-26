import Foundation

/// The local root of SPEC 6.1, as names and URLs.
///
/// ```
/// Library/Application Support/
///   targets.json                  <- beside the root, per 6.1
///   preference-rollback.json      <- beside the root, per 6.1 and 10.9
///   Backup/
///     state.sqlite
///     staging/
///     outbox/
///     restore/<blob hash>
/// ```
///
/// The two files beside the root are there on purpose. The root holds
/// cache and working files, and Empo may delete it whole.
public enum BackupRootLayout {

    public static let rootDirectoryName = "Backup"
    public static let stateDatabaseName = "state.sqlite"
    public static let stagingDirectoryName = "staging"
    public static let outboxDirectoryName = "outbox"
    public static let restoreDirectoryName = "restore"

    /// The target descriptors of 8.8. Section 8 owns the contents.
    public static let targetsFileName = "targets.json"
    /// The preference rollback undo of 10.9. Section 10 owns the
    /// contents.
    public static let preferenceRollbackFileName = "preference-rollback.json"

    public static func root(inApplicationSupport applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    public static func stateDatabase(root: URL) -> URL {
        root.appendingPathComponent(stateDatabaseName)
    }

    public static func staging(root: URL) -> URL {
        root.appendingPathComponent(stagingDirectoryName, isDirectory: true)
    }

    public static func outbox(root: URL) -> URL {
        root.appendingPathComponent(outboxDirectoryName, isDirectory: true)
    }

    public static func restore(root: URL) -> URL {
        root.appendingPathComponent(restoreDirectoryName, isDirectory: true)
    }

    /// A downloaded blob, keyed by its hash, per 6.4. A restarted
    /// restore re-verifies what is there and skips it for free.
    public static func restoreBlob(root: URL, hash: String) -> URL {
        restore(root: root).appendingPathComponent(hash)
    }

    public static func targetsFile(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(targetsFileName)
    }

    public static func preferenceRollbackFile(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(preferenceRollbackFileName)
    }

    /// The three working directories, which a fresh install and a
    /// deleted root both need.
    public static func createDirectories(root: URL) throws {
        let manager = FileManager.default
        for url in [root, staging(root: root), outbox(root: root), restore(root: root)] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

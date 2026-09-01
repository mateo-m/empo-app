import Foundation

/// The local root of SPEC 6.1, as names and URLs.
///
/// ```
/// Library/Application Support/
///   targets.json                  <- beside the root, per 6.1
///   preference-rollback.json      <- beside the root, per 6.1 and 10.9
///   sync.json                     <- beside the root, per 10.3
///   sync-profile-ids.json         <- beside the root, per 10.6
///   preferences.automerge         <- beside the root, per 10.3
///   Backup/
///     state.sqlite
///     staging/
///       packages/<package id>/     <- the backup packages of 12.5
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
    /// The backup packages of 12.5, while they build and while they
    /// wait for Files to confirm a save.
    public static let packagesDirectoryName = "packages"

    /// The target descriptors of 8.8. Section 8 owns the contents.
    public static let targetsFileName = "targets.json"
    /// The preference rollback undo of 10.9. Section 10 owns the
    /// contents.
    public static let preferenceRollbackFileName = "preference-rollback.json"
    /// This device's copy of the sync document of 10.3. It sits
    /// beside the root, because the root is a cache Empo may delete
    /// whole and the causal history must survive that.
    public static let syncDocumentFileName = "preferences.automerge"

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

    public static func packages(root: URL) -> URL {
        staging(root: root).appendingPathComponent(packagesDirectoryName, isDirectory: true)
    }

    /// One package, in its own directory, so a cancel deletes the
    /// partial ZIP and nothing else.
    public static func package(root: URL, id: String) -> URL {
        packages(root: root).appendingPathComponent(id, isDirectory: true)
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

    public static func syncDocumentFile(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(syncDocumentFileName)
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

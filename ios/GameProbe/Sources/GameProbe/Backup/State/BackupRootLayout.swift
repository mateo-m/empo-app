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
public struct BackupRootLayout: Equatable, Sendable {

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

    public let applicationSupport: URL

    public init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport
    }

    /// The layout a caller that holds the root alone reads. The root
    /// is always one directory inside Application Support, so the
    /// files beside it come from the parent.
    public init(root: URL) {
        self.applicationSupport = root.deletingLastPathComponent()
    }

    public var root: URL {
        applicationSupport.appendingPathComponent(
            Self.rootDirectoryName, isDirectory: true)
    }

    public var stateDatabase: URL {
        root.appendingPathComponent(Self.stateDatabaseName)
    }

    public var staging: URL {
        root.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
    }

    public var outbox: URL {
        root.appendingPathComponent(Self.outboxDirectoryName, isDirectory: true)
    }

    public var restore: URL {
        root.appendingPathComponent(Self.restoreDirectoryName, isDirectory: true)
    }

    public var packages: URL {
        staging.appendingPathComponent(Self.packagesDirectoryName, isDirectory: true)
    }

    /// One package, in its own directory, so a cancel deletes the
    /// partial ZIP and nothing else.
    public func package(id: String) -> URL {
        packages.appendingPathComponent(id, isDirectory: true)
    }

    /// A downloaded blob, keyed by its hash, per 6.4. A restarted
    /// restore re-verifies what is there and skips it for free.
    public func restoreBlob(hash: String) -> URL {
        restore.appendingPathComponent(hash)
    }

    public var targetsFile: URL {
        applicationSupport.appendingPathComponent(Self.targetsFileName)
    }

    public var preferenceRollbackFile: URL {
        applicationSupport.appendingPathComponent(Self.preferenceRollbackFileName)
    }

    public var syncDocumentFile: URL {
        applicationSupport.appendingPathComponent(Self.syncDocumentFileName)
    }

    /// The three working directories, which a fresh install and a
    /// deleted root both need.
    public func createDirectories() throws {
        let manager = FileManager.default
        for url in [root, staging, outbox, restore] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

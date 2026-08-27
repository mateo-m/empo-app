import Foundation

/// One object as `list` reports it, per SPEC 8.1.
public struct RemoteObject: Equatable, Sendable {
    /// The provider-relative path. There is no directory model, per
    /// 8.1, so the path is the whole name.
    public let path: String
    public let sizeBytes: Int64
    /// The object's own modified time, or `nil` on a target whose
    /// `reportsObjectAge` flag is false.
    public let modifiedAt: Date?

    public init(path: String, sizeBytes: Int64, modifiedAt: Date?) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

/// What a space query answers, per SPEC 8.1 and 9.7.
public struct QuotaReading: Equatable, Sendable {
    public let usedBytes: Int64
    /// The limit, or `nil` where the target states a use with no
    /// limit.
    public let limitBytes: Int64?

    public init(usedBytes: Int64, limitBytes: Int64?) {
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
    }

    public var freeBytes: Int64? {
        limitBytes.map { max(0, $0 - usedBytes) }
    }
}

/// Whether a put is durable on the remote, per SPEC 8.5.
public enum PutConfirmation: Equatable, Sendable {
    /// The object is durable. The manifest-last rule of 5.8 may now
    /// count this blob, and proven coverage of 11.12 may read it.
    case confirmed
    /// The bytes left this device, and the remote has not reported
    /// the object durable yet. iCloud Drive behaves this way.
    case pending
}

/// The six operations every provider meets, per SPEC 8.1.
///
/// Paths are provider-relative and flat. There is no directory
/// model, no `move`, and no rename. The engine talks to this
/// protocol alone and never branches on the provider name.
///
/// `put` promises atomicity, per 8.2: a path holds either the old
/// content or the complete new content, and a reader never sees a
/// torn write. That promise is what lets the engine write
/// `writer.json` and `device.json` as ordinary puts.
///
/// Resumability is internal to `put` and never reaches the engine,
/// which retries a whole put.
public protocol BackupProvider: Sendable {

    /// The five flags of 8.3. They are fixed for the life of the
    /// provider. `canQueryQuota` comes from the add-time permission
    /// check and rides the target descriptor.
    var capabilities: TargetCapabilities { get }

    /// Every object whose path starts with `prefix`.
    ///
    /// No run calls this. Its five callers are the sweep of 5.11,
    /// the permission check of 8.7, the fresh-install scan of 11.3,
    /// the namespace list of 13.9, and the preference-sync pass of
    /// 10.5.
    func list(prefix: String) async throws(BackupProviderError) -> [RemoteObject]

    /// Uploads one file.
    ///
    /// It always reads from a file, because a background URLSession
    /// uploads from a file alone. Inside the provider it is two
    /// phases: stage, then commit.
    func put(localFile: URL, path: String) async throws(BackupProviderError)

    /// Whether the object at `path` is durable on the remote.
    ///
    /// Throws `notFound` when the target holds no object there.
    func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation

    /// Downloads one object to `localFile`.
    func get(path: String, localFile: URL) async throws(BackupProviderError)

    /// Deletes a batch. A path that holds no object is not an error,
    /// because the delete has already got what it asked for.
    func delete(paths: [String]) async throws(BackupProviderError)

    /// The used bytes and the limit, or `nil` where this target does
    /// not answer a space query, per 9.7.
    func quota() async throws(BackupProviderError) -> QuotaReading?
}

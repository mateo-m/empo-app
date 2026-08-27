import Foundation

/// The five capability flags of SPEC 8.3.
///
/// The engine reads these. It never branches on the provider name.
public struct TargetCapabilities: Equatable, Sendable {

    /// Whether this target answers a space query. The add-time
    /// permission check of 8.7 sets it per target, not per provider,
    /// because WebDAV and SFTP answer only on some servers, per 9.7.
    public var canQueryQuota: Bool

    /// Whether `list` reports an object's own modified time. The
    /// sweep of 5.11 needs it. All six v1 providers report it. A
    /// later provider that does not gets the manual reclaim action
    /// of section 13 in place of an automatic sweep.
    public var reportsObjectAge: Bool

    /// Whether the target can hand a transfer to the system. False
    /// for SFTP alone in v1, and 8.9 covers what such a target does.
    public var supportsBackgroundTransfer: Bool

    /// The largest single file the target takes, or `nil` where the
    /// server sets the limit and states no number.
    public var maxFileSize: Int64?

    /// Whether the target treats two names that differ only in case
    /// as one object. True for Dropbox. Every name Empo writes is a
    /// hex key or a fixed ASCII name, per 5.2, so v1 behavior does
    /// not change. The flag stops a later feature from assuming the
    /// opposite.
    public var foldsCase: Bool

    public init(
        canQueryQuota: Bool = false,
        reportsObjectAge: Bool = true,
        supportsBackgroundTransfer: Bool = true,
        maxFileSize: Int64? = nil,
        foldsCase: Bool = false
    ) {
        self.canQueryQuota = canQueryQuota
        self.reportsObjectAge = reportsObjectAge
        self.supportsBackgroundTransfer = supportsBackgroundTransfer
        self.maxFileSize = maxFileSize
        self.foldsCase = foldsCase
    }

    /// The error a file of this size earns, or `nil` when it fits.
    ///
    /// Every provider calls this before it moves a byte. A file over
    /// the limit is a permanent refusal, so it is `rejected` and not
    /// `outOfSpace`. The prune ladder of 5.14 frees space, and no
    /// amount of space makes a too-large file fit.
    public func rejection(forFileOfSize size: Int64) -> BackupProviderError? {
        guard let maxFileSize, size > maxFileSize else { return nil }
        return .rejected(
            message: "the file is \(size) bytes and this target takes at most \(maxFileSize)")
    }
}

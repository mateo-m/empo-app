import Foundation

/// One file the backup set holds, per SPEC 3.1 to 3.6.
///
/// A member becomes a `SnapshotManifest.Entry` once ticket 006 hashes
/// and uploads it, so the fields line up with that entry: the same
/// root, the same relative path, and the same detection source.
public struct BackupSetMember: Equatable, Sendable {

    /// The named root the path starts from, per 5.5 and 4.5.
    public var root: EntryRoot
    /// The path, relative to `root`, with `/` as the separator.
    public var path: String
    public var size: Int64
    public var modifiedAt: Date
    /// Which of the three sources of 3.6 found the member.
    ///
    /// `nil` for a full-mode tree and for the always-in members of
    /// 3.1, because no source found those: the mode and the rules
    /// put them there.
    public var detectionSource: DetectionSource?

    public init(
        root: EntryRoot,
        path: String,
        size: Int64,
        modifiedAt: Date,
        detectionSource: DetectionSource? = nil
    ) {
        self.root = root
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
        self.detectionSource = detectionSource
    }
}

/// What one game's backup set holds, plus the outside members 4.5
/// records in the manifest header.
public struct GameBackupSet: Equatable, Sendable {

    public var mode: BackupMode
    /// The members, sorted by root and then by path, so two runs of
    /// the resolver over one tree give one answer.
    public var members: [BackupSetMember]
    /// The shared data directory the game resolved to, per 4.5. The
    /// manifest header records it, and the blob store stays
    /// path-keyed underneath, so a directory two games name uploads
    /// once.
    public var sharedDataDirectory: String?
    /// The Rescued Saves buckets that match this game, per 4.5.
    public var rescuedSavesBuckets: [String]

    public init(
        mode: BackupMode,
        members: [BackupSetMember] = [],
        sharedDataDirectory: String? = nil,
        rescuedSavesBuckets: [String] = []
    ) {
        self.mode = mode
        self.members = members
        self.sharedDataDirectory = sharedDataDirectory
        self.rescuedSavesBuckets = rescuedSavesBuckets
    }

    public var totalSize: Int64 {
        members.reduce(0) { $0 + $1.size }
    }

    /// The members under one root, in the order they were resolved.
    public func members(under root: EntryRoot) -> [BackupSetMember] {
        members.filter { $0.root == root }
    }
}

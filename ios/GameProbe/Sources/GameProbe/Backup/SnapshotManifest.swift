import Foundation

/// What a snapshot covers, per SPEC 3.3 and 3.4.
public enum BackupMode: String, Codable, Sendable, CaseIterable, Equatable {
    case full
    case slim
}

/// Which source found a member, per SPEC 3.6. Every member of a
/// slim-mode set carries one. Section 7.2 reads it.
public enum DetectionSource: String, Codable, Sendable, CaseIterable, Equatable {
    /// The `PortableGameSaves` signals.
    case classifier
    /// A write Empo saw while the game ran.
    case runtimeWatch = "runtime-watch"
    /// The user marked the file or the folder.
    case manualMark = "manual-mark"
}

/// The named root a manifest entry's path starts from, per SPEC 5.5
/// and 4.5.
public enum EntryRoot: String, Codable, Sendable, CaseIterable, Equatable {
    /// The game's own container folder.
    case container
    /// The shared data directory the game resolved to.
    case sharedData = "shared-data"
    /// A `Rescued Saves` bucket. The bucket name opens the path.
    case rescuedSaves = "rescued-saves"
    /// The stream that belongs to no game: the UserDefaults export
    /// and the layout profiles.
    case preferences
}

/// What a manifest rejected, and where.
public enum ManifestFailure: Error, Equatable {
    case unknownRoot(label: String, path: String)
    case unknownCompression(algorithm: String, path: String)
    case unknownDetectionSource(label: String, path: String)
}

/// One snapshot, per SPEC 5.5.
///
/// A manifest is self-contained: it lists every member of that
/// snapshot, so it depends on no earlier manifest and a prune can
/// break no chain.
///
/// The preferences stream of 5.3 has no game, so it carries an empty
/// container name and the marker of a tree it does not have.
public struct SnapshotManifest: Codable, Equatable, Sendable {

    /// The version marker of SPEC 4.4. It is not part of game
    /// identity, so a game that updates itself keeps one identity.
    public struct VersionMarker: Codable, Equatable, Sendable {
        /// The hash of the `Game.ini` bytes.
        public var gameINIHash: String?
        /// `manifestVersion`, when the import was JGP.
        public var jgpManifestVersion: String?
        public var fileCount: Int
        public var totalSize: Int64

        public init(
            gameINIHash: String? = nil,
            jgpManifestVersion: String? = nil,
            fileCount: Int = 0,
            totalSize: Int64 = 0
        ) {
            self.gameINIHash = gameINIHash
            self.jgpManifestVersion = jgpManifestVersion
            self.fileCount = fileCount
            self.totalSize = totalSize
        }
    }

    /// One member of the snapshot, per SPEC 5.5.
    public struct Entry: Codable, Equatable, Sendable {
        /// The root the path starts from.
        public var root: EntryRoot
        /// The path, relative to `root`.
        public var path: String
        public var size: Int64
        public var modifiedAt: Date
        /// The content hash, which also names the blob.
        public var hash: String
        /// How this blob is stored, per 5.6.
        public var compression: BlobCompression
        /// The file changed twice during staging, so its bytes are
        /// from one moment and its neighbours are from another, per
        /// 5.9. The path retries on the next run.
        public var partial: Bool
        /// Which source found the member, per 3.6. `nil` where no
        /// source found the member: the always-in files of 3.1, and
        /// the rest of a full-mode tree. A full-mode entry that a
        /// source did find keeps its label, because 7.2 reads it to
        /// tell a partial save from a partial log.
        public var detectionSource: DetectionSource?
        /// Reserved. A later format version points an entry at a
        /// chunk list here, per 5.5 and 15.2. Version 1 never writes
        /// it, and it must survive a read and a write untouched, so
        /// that adding it later breaks nothing.
        public var chunks: [String]?

        public init(
            root: EntryRoot,
            path: String,
            size: Int64,
            modifiedAt: Date,
            hash: String,
            compression: BlobCompression,
            partial: Bool = false,
            detectionSource: DetectionSource? = nil,
            chunks: [String]? = nil
        ) {
            self.root = root
            self.path = path
            self.size = size
            self.modifiedAt = modifiedAt
            self.hash = hash
            self.compression = compression
            self.partial = partial
            self.detectionSource = detectionSource
            self.chunks = chunks
        }

        private enum CodingKeys: String, CodingKey {
            case root, path, size, modifiedAt, hash, compression, partial
            case detectionSource, chunks
        }

        /// Decoded by hand so a rejected value names the path it came
        /// from. The automatic decoder reports an index instead.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let path = try values.decode(String.self, forKey: .path)
            self.path = path

            // One shape for the three labelled values: decode the
            // string, map it, and name the path when it does not map.
            func label<T: RawRepresentable>(
                _ key: CodingKeys, _ failure: (String, String) -> ManifestFailure
            ) throws -> T where T.RawValue == String {
                let raw = try values.decode(String.self, forKey: key)
                guard let value = T(rawValue: raw) else { throw failure(raw, path) }
                return value
            }

            self.root = try label(.root, ManifestFailure.unknownRoot)
            self.compression = try label(.compression, ManifestFailure.unknownCompression)
            if let raw = try values.decodeIfPresent(String.self, forKey: .detectionSource) {
                guard let source = DetectionSource(rawValue: raw) else {
                    throw ManifestFailure.unknownDetectionSource(label: raw, path: path)
                }
                self.detectionSource = source
            } else {
                self.detectionSource = nil
            }

            self.size = try values.decode(Int64.self, forKey: .size)
            self.modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
            self.hash = try values.decode(String.self, forKey: .hash)
            self.partial = try values.decodeIfPresent(Bool.self, forKey: .partial) ?? false
            self.chunks = try values.decodeIfPresent([String].self, forKey: .chunks)
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(root.rawValue, forKey: .root)
            try values.encode(path, forKey: .path)
            try values.encode(size, forKey: .size)
            try values.encode(modifiedAt, forKey: .modifiedAt)
            try values.encode(hash, forKey: .hash)
            try values.encode(compression.rawValue, forKey: .compression)
            try values.encode(partial, forKey: .partial)
            try values.encodeIfPresent(detectionSource?.rawValue, forKey: .detectionSource)
            try values.encodeIfPresent(chunks, forKey: .chunks)
        }
    }

    // MARK: - Header, per 5.5

    /// Mirrors the integer of `format.json`, per 5.16 and 15.1.
    public var formatVersion: Int
    public var mode: BackupMode
    /// The exact container folder name. `gameKey` is its hash.
    public var containerFolderName: String
    /// The identity alias, when the game has one.
    public var identityAlias: String?
    public var versionMarker: VersionMarker
    /// The shared data directory the game resolved to, per 4.5.
    public var sharedDataDirectory: String?
    /// The `Rescued Saves` buckets that match this game, per 4.5.
    public var rescuedSavesBuckets: [String]
    public var entries: [Entry]

    public init(
        formatVersion: Int = FormatDescriptor.currentVersion,
        mode: BackupMode,
        containerFolderName: String,
        identityAlias: String? = nil,
        versionMarker: VersionMarker = VersionMarker(),
        sharedDataDirectory: String? = nil,
        rescuedSavesBuckets: [String] = [],
        entries: [Entry] = []
    ) {
        self.formatVersion = formatVersion
        self.mode = mode
        self.containerFolderName = containerFolderName
        self.identityAlias = identityAlias
        self.versionMarker = versionMarker
        self.sharedDataDirectory = sharedDataDirectory
        self.rescuedSavesBuckets = rescuedSavesBuckets
        self.entries = entries
    }

    /// The key of the game's folder under `games/`, per 5.2.
    public var gameKey: String {
        BackupKeys.gameKey(containerFolderName: containerFolderName)
    }

    /// What a reader may do with the namespace this manifest is in,
    /// per 5.16. The manifests of the namespace answer the question,
    /// not the `format.json` of a target another device may have
    /// moved on.
    public var access: FormatAccess {
        FormatDescriptor.namespaceAccess(manifestFormatVersion: formatVersion)
    }

    // MARK: - The JSON codec

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(json data: Data) throws -> SnapshotManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(SnapshotManifest.self, from: data)
    }

    /// A manifest goes to the target compressed, per 5.6. Tens of KB
    /// of JSON deflate to a few KB.
    public func compressedData() throws -> Data {
        try BlobCodec.encodeZlib(jsonData())
    }

    public static func decode(compressed data: Data) throws -> SnapshotManifest {
        try decode(json: BlobCodec.decode(data, algorithm: .zlib))
    }
}

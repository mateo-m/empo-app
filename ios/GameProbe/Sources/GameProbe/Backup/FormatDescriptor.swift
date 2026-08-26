import Foundation

/// What a reader may do with a target or with one namespace, per
/// SPEC 5.16 and 15.1.
///
/// An app that meets a newer format version goes read-only. It still
/// lists and restores what it can parse, and it refuses every write
/// and every prune, because a prune by a reader that misunderstands
/// the format is the one action that destroys data. A reader
/// therefore lists and restores in every state, and only the write
/// and the prune have a question to ask.
public enum FormatAccess: Equatable, Sendable {
    case readWrite
    case readOnly(Restriction)

    public enum Restriction: Equatable, Sendable {
        /// The data carries a version this build does not know.
        case newerFormatVersion(Int)
        /// The data does not parse, so the layout is not trusted.
        case unreadableFormat
    }

    public var allowsWrite: Bool { self == .readWrite }

    public var allowsPrune: Bool { self == .readWrite }
}

/// `Empo/format.json`, per SPEC 5.1 and 5.16.
///
/// It records what created the target and what its shared `devices/`
/// tree means: the format version, the hash function by name, the
/// blob naming rule, and the fan-out width. A reader takes the last
/// three from this file and never assumes them, per 15.3, so a
/// version 2 can change any of them.
public struct FormatDescriptor: Codable, Equatable, Sendable {

    /// The version this build writes, per 15.1.
    public static let currentVersion = 1

    /// The only blob naming rule version 1 states: the file name is
    /// the lowercase hex hash.
    public static let hashHexNaming = "hash-hex"

    /// The fan-out width version 1 states, per 5.1.
    public static let version1FanOutWidth = 2

    public var formatVersion: Int
    public var hashFunction: String
    public var blobNaming: String
    public var fanOutWidth: Int

    public init(
        formatVersion: Int = FormatDescriptor.currentVersion,
        hashFunction: String = ContentHash.functionName,
        blobNaming: String = FormatDescriptor.hashHexNaming,
        fanOutWidth: Int = FormatDescriptor.version1FanOutWidth
    ) {
        self.formatVersion = formatVersion
        self.hashFunction = hashFunction
        self.blobNaming = blobNaming
        self.fanOutWidth = fanOutWidth
    }

    // MARK: - Read and write

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(json data: Data) throws -> FormatDescriptor {
        try JSONDecoder().decode(FormatDescriptor.self, from: data)
    }

    /// The path of a blob with this hash, under the rule this
    /// descriptor states.
    public func blobPath(hash: String) -> String {
        BackupKeys.blobPath(hash: hash, fanOutWidth: fanOutWidth)
    }

    // MARK: - The read-only test of 5.16

    /// Whether this descriptor states a layout version 1 defines. A
    /// version 1 file that names another hash function, another
    /// naming rule, or another width is not a version 1 file, so the
    /// target goes read-only. A read-only reader still lists and
    /// restores, and `blobPath` still obeys the width the file
    /// declares, per 15.3. Only the write and the prune stop.
    public var describesKnownLayout: Bool {
        guard formatVersion >= 1 else { return false }
        guard formatVersion == FormatDescriptor.currentVersion else { return true }
        return hashFunction == ContentHash.functionName
            && blobNaming == FormatDescriptor.hashHexNaming
            && fanOutWidth == FormatDescriptor.version1FanOutWidth
    }

    /// What a reader may do with the whole target, from the bytes of
    /// `Empo/format.json`.
    ///
    /// A device that cannot parse `format.json` treats the whole
    /// target as read-only, per 5.16, because it cannot trust the
    /// layout it is about to walk. `nil` covers a missing file.
    public static func targetAccess(formatJSON data: Data?) -> FormatAccess {
        guard let data, let descriptor = try? decode(json: data) else {
            return .readOnly(.unreadableFormat)
        }
        guard descriptor.describesKnownLayout else {
            return .readOnly(.unreadableFormat)
        }
        guard descriptor.formatVersion <= currentVersion else {
            return .readOnly(.newerFormatVersion(descriptor.formatVersion))
        }
        return .readWrite
    }

    /// What a reader may do with one namespace, from the version its
    /// own manifests carry.
    ///
    /// The integer that governs one namespace is the one its
    /// manifests carry, per 5.16 and 15.4, so a second device that
    /// moves to a later version never makes this device's namespace
    /// read-only.
    public static func namespaceAccess(manifestFormatVersion version: Int) -> FormatAccess {
        guard version >= 1 else { return .readOnly(.unreadableFormat) }
        guard version <= currentVersion else {
            return .readOnly(.newerFormatVersion(version))
        }
        return .readWrite
    }
}

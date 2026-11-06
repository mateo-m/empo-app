import Foundation

/// Which stream a snapshot belongs to, per SPEC 5.3.
///
/// The state store keys its rows by `gameKey`. The stream that
/// belongs to no game needs a key there too, so it takes the key of
/// the empty container name. A real container name is never empty,
/// so the two can never collide.
public enum BackupStream: Equatable, Sendable {

    case game(key: String)
    /// The UserDefaults export, the layout profiles, and the Rescued
    /// Saves buckets that match no installed game.
    case preferences

    /// The key the state store rows carry.
    public var key: String {
        switch self {
        case .game(let key): return key
        case .preferences: return BackupStream.preferencesKey
        }
    }

    /// The key of the stream that belongs to no game.
    public static let preferencesKey = BackupKeys.gameKey(containerFolderName: "")

    public init(key: String) {
        self = key == BackupStream.preferencesKey ? .preferences : .game(key: key)
    }
}

/// The provider paths of SPEC 5.1, for one target root and one
/// namespace.
///
/// `BackupKeys` names the parts inside a namespace. This type joins
/// them to the fixed root of 8.7, so the engine hands the provider a
/// whole path and never builds one by hand.
public struct BackupNamespacePaths: Equatable, Sendable {

    public static let empoDirectoryName = "Empo"
    public static let devicesDirectoryName = "devices"
    public static let formatFileName = "format.json"
    public static let writerFileName = "writer.json"
    public static let deviceFileName = "device.json"
    /// This device's copy of the sync document of section 10, per
    /// 5.1. Only the owning device writes it.
    public static let syncDocumentFileName = "preferences.automerge"
    public static let gamesDirectoryName = "games"
    public static let preferencesDirectoryName = "prefs"
    public static let manifestFileExtension = "json"

    /// The fixed root of 8.7. An empty root puts `Empo/` at the top
    /// of the target.
    public let root: String
    public let namespaceId: String

    public init(root: String, namespaceId: String) {
        self.root = root
        self.namespaceId = namespaceId
    }

    /// The same target under a second namespace, which is what the
    /// split of 5.12 makes.
    public func inNamespace(_ namespaceId: String) -> BackupNamespacePaths {
        BackupNamespacePaths(root: root, namespaceId: namespaceId)
    }

    // MARK: - The target

    public var empoPrefix: String {
        Self.join(root, Self.empoDirectoryName)
    }

    public var formatFile: String {
        Self.join(empoPrefix, Self.formatFileName)
    }

    public var devicesPrefix: String {
        Self.join(empoPrefix, Self.devicesDirectoryName)
    }

    // MARK: - The namespace

    public var namespacePrefix: String {
        Self.join(devicesPrefix, namespaceId)
    }

    public var writerFile: String {
        Self.join(namespacePrefix, Self.writerFileName)
    }

    public var deviceFile: String {
        Self.join(namespacePrefix, Self.deviceFileName)
    }

    public var syncDocumentFile: String {
        Self.join(namespacePrefix, Self.syncDocumentFileName)
    }

    public var blobsPrefix: String {
        Self.join(namespacePrefix, "blobs")
    }

    /// The width comes from `format.json`, per 15.3. A reader must
    /// never assume it.
    public func blobPath(hash: String, fanOutWidth: Int) -> String {
        Self.join(
            namespacePrefix,
            BackupKeys.blobPath(hash: hash, fanOutWidth: fanOutWidth))
    }

    // MARK: - The streams

    public var gamesPrefix: String {
        Self.join(namespacePrefix, Self.gamesDirectoryName)
    }

    public var preferencesPrefix: String {
        Self.join(namespacePrefix, Self.preferencesDirectoryName)
    }

    /// Everything one stream's manifests sit under, with the closing
    /// separator, so a prefix match cannot reach a second stream.
    public func prefix(of stream: BackupStream) -> String {
        switch stream {
        case .game(let key):
            return Self.join(gamesPrefix, key) + "/"
        case .preferences:
            return preferencesPrefix + "/"
        }
    }

    public func manifestPath(stream: BackupStream, snapshotId: String) -> String {
        prefix(of: stream) + snapshotId + "." + Self.manifestFileExtension
    }

    /// The snapshot id a manifest path names, or `nil` when the path
    /// does not carry the form of 5.2.
    public static func snapshotId(ofManifestPath path: String) -> String? {
        guard let name = path.split(separator: "/").last else { return nil }
        let suffix = "." + manifestFileExtension
        guard name.hasSuffix(suffix) else { return nil }
        let id = String(name.dropLast(suffix.count))
        guard BackupKeys.timestamp(ofSnapshotId: id) != nil else { return nil }
        return id
    }

    // MARK: - Helpers

    /// Joins two path parts with one separator, and drops an empty
    /// part, so an empty root leaves no leading separator.
    public static func join(_ left: String, _ right: String) -> String {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left.hasSuffix("/") ? left + right : left + "/" + right
    }
}

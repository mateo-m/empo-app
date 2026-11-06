import Foundation

/// Where a backup set member's bytes are on this device.
///
/// The resolver of ticket 003 gives each member a named root and a
/// path relative to it, per 5.5. The engine has to read the file
/// again to hash it, so this maps the pair back to a URL.
public struct MemberSource: Sendable {

    /// `Documents/Games/<folderName>/`.
    public var container: URL?
    /// The shared data directory the game resolved to, per 4.5.
    public var sharedData: URL?
    /// The Rescued Saves buckets, keyed by bucket name.
    public var rescuedBuckets: [String: URL]
    /// `Documents/Profiles/`, the layout profiles of 3.1.
    public var profiles: URL?
    /// The UserDefaults export of 3.1.
    public var userDefaultsExport: URL?

    public init(
        container: URL? = nil,
        sharedData: URL? = nil,
        rescuedBuckets: [String: URL] = [:],
        profiles: URL? = nil,
        userDefaultsExport: URL? = nil
    ) {
        self.container = container
        self.sharedData = sharedData
        self.rescuedBuckets = rescuedBuckets
        self.profiles = profiles
        self.userDefaultsExport = userDefaultsExport
    }

    public init(game request: GameBackupSetRequest) {
        self.init(
            container: request.containerURL,
            sharedData: request.sharedDataDirectory,
            rescuedBuckets: request.rescuedSavesBuckets)
    }

    public init(library request: LibraryBackupSetRequest) {
        self.init(
            rescuedBuckets: request.rescuedSavesBuckets,
            profiles: request.profilesDirectory,
            userDefaultsExport: request.userDefaultsExportFile)
    }

    /// The file one member names, or `nil` where this device holds
    /// no root for it.
    public func url(of member: BackupSetMember) -> URL? {
        url(root: member.root, path: member.path)
    }

    /// The file one manifest entry names. A restore reads it the
    /// same way a run does, per 11.1, because both name the same
    /// roots.
    public func url(of entry: SnapshotManifest.Entry) -> URL? {
        url(root: entry.root, path: entry.path)
    }

    public func url(root: EntryRoot, path: String) -> URL? {
        switch root {
        case .container:
            return container?.appendingPathComponent(path)
        case .sharedData:
            return sharedData?.appendingPathComponent(path)
        case .rescuedSaves:
            return bucketFile(path)
        case .preferences:
            return preferencesFile(path)
        }
    }

    /// `<bucket name>/<path inside it>`, per the resolver of 3.
    private func bucketFile(_ path: String) -> URL? {
        let parts = path.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let bucket = rescuedBuckets[String(parts[0])] else { return nil }
        return bucket.appendingPathComponent(String(parts[1]))
    }

    private func preferencesFile(_ path: String) -> URL? {
        switch PreferencesMemberPath(path) {
        case .userDefaultsExport:
            return userDefaultsExport
        case .profile(let inside):
            return profiles?.appendingPathComponent(inside)
        case .rescuedSavesBucket(let name, let inside):
            return rescuedBuckets[name]?.appendingPathComponent(inside)
        case nil:
            return nil
        }
    }
}

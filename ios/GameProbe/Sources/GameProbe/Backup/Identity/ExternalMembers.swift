import Foundation

/// The members that live outside a game's container, per SPEC 4.5:
/// the shared data directory the game resolved to, and the Rescued
/// Saves buckets that match it.
///
/// A snapshot records the link, which is what makes "restore this
/// game's saves" one action. Storage stays path-keyed underneath, so
/// a directory two games share uploads once.
public enum ExternalMembers {

    // MARK: - The recorded path

    /// The path a manifest header records for a directory, per 4.5.
    ///
    /// It is relative to `Documents/`, because the absolute path
    /// holds an app-container id that no second device and no second
    /// install can rebuild. `Documents/Data/kikiyama/yumenikki`
    /// records as `Data/kikiyama/yumenikki`.
    ///
    /// A directory outside `Documents/` records its absolute path.
    /// Nothing in Empo puts one there, and a path that cannot be
    /// made relative is better recorded than dropped.
    public static func recordedPath(of url: URL, documentsRoot: URL) -> String {
        let base = documentsRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }

    /// `Documents/Data/`, the parent of every shared data directory.
    public static let sharedRootName = "Data"

    /// The directory a recorded path names on this device, or `nil`
    /// for a path outside `Data/`. A restore reads the path from the
    /// storage service, and a `..` step or another root would write
    /// into another game's files.
    public static func url(ofRecordedPath path: String, documentsRoot: URL) -> URL? {
        guard staysInSharedData(path) else { return nil }
        return documentsRoot.appendingPathComponent(path, isDirectory: true)
    }

    public static func staysInSharedData(_ path: String) -> Bool {
        guard (try? PackageValidation.checkThePath(path)) != nil else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count > 1 && parts[0] == sharedRootName
            && !parts.contains { $0.isEmpty || $0 == "." }
    }

    // MARK: - A path that moved

    /// Where a game's shared data directory is now, and where it was.
    public struct SharedDataHistory: Equatable, Sendable {
        /// The path the newest snapshot recorded.
        public var current: String?
        /// The paths earlier snapshots recorded, newest first, each
        /// one once.
        public var previous: [String]

        public init(current: String? = nil, previous: [String] = []) {
            self.current = current
            self.previous = previous
        }
    }

    /// The shared data directory across a game's snapshots, oldest
    /// snapshot first. `<snapshotId>` sorts by name, per 5.2, so the
    /// caller sorts on the id.
    ///
    /// A path that moves between two snapshots is an ordinary event,
    /// per 4.5. Empo records the new path, keeps the old data in the
    /// game's history, offers the newest on restore, and alerts
    /// nobody. Empo cannot tell a legitimate move from a stranded
    /// directory, and an alert on every mkxp.json edit teaches the
    /// user to dismiss it.
    public static func sharedDataHistory(
        ofSnapshotsOldestFirst manifests: [SnapshotManifest]
    ) -> SharedDataHistory {
        var seen: [String] = []
        for manifest in manifests {
            guard let path = manifest.sharedDataDirectory else { continue }
            seen.removeAll { $0 == path }
            seen.append(path)
        }
        guard let current = seen.last else { return SharedDataHistory() }
        return SharedDataHistory(
            current: current,
            previous: Array(seen.dropLast().reversed()))
    }
}

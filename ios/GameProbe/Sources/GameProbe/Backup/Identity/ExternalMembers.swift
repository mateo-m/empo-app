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
        RelativePath.staysUnderItsRoot(path) && path.hasPrefix(sharedRootName + "/")
    }
}

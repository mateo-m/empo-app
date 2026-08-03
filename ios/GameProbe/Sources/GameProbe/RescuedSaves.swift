import Foundation

/// Buckets for portable saves rescued from a deleted game.
///
/// `Data/` replicates Windows paths that live OUTSIDE a game's
/// folder (`%APPDATA%`, `Saved Games`), so portable saves - files a
/// game keeps next to its own files - must not land there: a
/// re-imported game reads them from `Game/`, never from the shared
/// data directory. The deletion rescue moves them into
///
///     Rescued Saves/<display title>/
///
/// with their structure intact, so a later import of the same game
/// can put them back where the game expects them.
///
/// The bucket name follows the app's display naming (custom title
/// first, INI title as the fallback), so the bucket alone cannot
/// identify the game. A marker file inside the bucket records the
/// INI-derived container folder name - the same identity import
/// matching uses - and `matchingBuckets` matches on it. A bucket
/// without a readable marker (hand-made, or a failed restore that
/// could not rewrite it) still matches by its directory name.
public enum RescuedSaves {

    /// Name of the shared bucket root, a sibling of `Games/` and
    /// `Data/` under Documents.
    public static let directoryName = "Rescued Saves"

    /// Marker file inside each bucket. Dot-prefixed: invisible in
    /// casual Files browsing, and excluded from the restore drain.
    public static let markerName = ".empo-origin.json"

    /// What the marker records: the INI-derived, sanitized folder
    /// name the game's container used (`GameFolderName.sanitize` of
    /// the INI title chain), which is what a later import of the
    /// same game resolves to regardless of any custom title.
    public struct Identity: Codable, Equatable, Sendable {
        public let folderName: String

        public init(folderName: String) {
            self.folderName = folderName
        }
    }

    /// Writes (or rewrites) the bucket's identity marker.
    @discardableResult
    public static func writeMarker(
        _ identity: Identity, inBucket bucket: URL, fm: FileManager = .default
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(identity) else { return false }
        return fm.createFile(
            atPath: bucket.appendingPathComponent(markerName).path,
            contents: data)
    }

    public static func readMarker(
        inBucket bucket: URL, fm: FileManager = .default
    ) -> Identity? {
        guard let data = fm.contents(atPath: bucket.appendingPathComponent(markerName).path)
        else { return nil }
        return try? JSONDecoder().decode(Identity.self, from: data)
    }

    /// Buckets under `root` that belong to the game whose container
    /// folder name is `folderName`, sorted by name for determinism.
    /// A bucket matches when its marker's identity matches
    /// case-insensitively - or, with no readable marker, when its
    /// own directory name does.
    public static func matchingBuckets(
        in root: URL, folderName: String, fm: FileManager = .default
    ) -> [URL] {
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let wanted = folderName.lowercased()
        return entries.sorted().compactMap { name in
            let bucket = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: bucket.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            if let identity = readMarker(inBucket: bucket, fm: fm) {
                return identity.folderName.lowercased() == wanted ? bucket : nil
            }
            return name.lowercased() == wanted ? bucket : nil
        }
    }

    /// Drains a bucket back into a freshly imported `Game/` tree
    /// with the `LegacyDataDrain` rules (recursive merge, the newer
    /// file wins, the loser stays beside it, nothing deleted). The
    /// marker never travels: it is removed first and written back
    /// if anything failed to move, so a partial restore stays
    /// identifiable for the next attempt. A complete restore
    /// removes the emptied bucket.
    @discardableResult
    public static func restore(
        from bucket: URL, into gameRoot: URL, fm: FileManager = .default
    ) -> LegacyDataDrain.Outcome {
        let identity = readMarker(inBucket: bucket, fm: fm)
        try? fm.removeItem(at: bucket.appendingPathComponent(markerName))
        let outcome = LegacyDataDrain.drain(from: bucket, into: gameRoot, fm: fm)
        if !outcome.isComplete, let identity {
            writeMarker(identity, inBucket: bucket, fm: fm)
        }
        return outcome
    }
}

import Foundation

/// One file this device holds where a restore may write, as the
/// planner needs it.
///
/// The caller walks the local roots and fills this in. `hash` is
/// there so an unchanged file costs nothing: where the local bytes
/// already match the snapshot's, the restore writes nothing and
/// leaves no displaced copy behind. A `nil` hash means the caller
/// could not read one, and the planner then displaces, because the
/// rule of 11.1 is that the snapshot wins the name.
public struct RestoreLocalFile: Equatable, Sendable {

    public var root: EntryRoot
    public var path: String
    public var size: Int64
    public var hash: String?

    public init(root: EntryRoot, path: String, size: Int64, hash: String? = nil) {
        self.root = root
        self.path = path
        self.size = size
        self.hash = hash
    }
}

/// What the restore does at one path, per SPEC 11.1 and 11.2.
public enum RestoreAction: Equatable, Sendable {
    /// The local tree holds nothing there. The restore is additive.
    case write
    /// The local tree holds a different file there. It moves aside
    /// under the named path, and the restored file takes the real
    /// name.
    case writeAfterDisplacing(String)
    /// The local bytes already match the snapshot's. Nothing is
    /// written and nothing is displaced.
    case unchanged
}

/// One entry of the plan.
public struct RestoreStep: Equatable, Sendable {

    public var entry: SnapshotManifest.Entry
    public var action: RestoreAction

    public init(entry: SnapshotManifest.Entry, action: RestoreAction) {
        self.entry = entry
        self.action = action
    }
}

/// One blob the restore has to have on this device before it writes.
public struct RestoreBlob: Equatable, Sendable {

    public var hash: String
    public var compression: BlobCompression
    /// The size of the file the blob decodes to. The blob itself
    /// stages compressed, so this is an upper bound on what the
    /// staged copy costs.
    public var sizeBytes: Int64

    public init(hash: String, compression: BlobCompression, sizeBytes: Int64) {
        self.hash = hash
        self.compression = compression
        self.sizeBytes = sizeBytes
    }
}

/// What one restore will do, decided before a byte moves.
///
/// The plan is pure. It reads a manifest and a listing of the local
/// tree, and it answers with the writes, the displacements, and the
/// blobs to fetch. The engine of ticket 014's app half carries it
/// out, and the sheets of ticket 017 read it.
public struct RestorePlan: Equatable, Sendable {

    public var scope: RestoreScope
    public var steps: [RestoreStep]
    /// The blobs to stage, in path order, with each hash once.
    public var blobs: [RestoreBlob]
    /// What the restored files take on disk.
    public var bytesToWrite: Int64
    /// What the blobs that are not staged yet take on disk. An upper
    /// bound, because a compressed blob stages smaller than the file
    /// it decodes to.
    public var bytesToStage: Int64
    /// The paths the snapshot marked `partial`, per 5.9. They
    /// restore with no question, and the summary of 11.14 names how
    /// many there were.
    public var partialPaths: [String]
    public var showsVersionMarkerSheet: Bool

    public init(
        scope: RestoreScope,
        steps: [RestoreStep] = [],
        blobs: [RestoreBlob] = [],
        bytesToWrite: Int64 = 0,
        bytesToStage: Int64 = 0,
        partialPaths: [String] = [],
        showsVersionMarkerSheet: Bool = false
    ) {
        self.scope = scope
        self.steps = steps
        self.blobs = blobs
        self.bytesToWrite = bytesToWrite
        self.bytesToStage = bytesToStage
        self.partialPaths = partialPaths
        self.showsVersionMarkerSheet = showsVersionMarkerSheet
    }

    public var writeCount: Int {
        steps.filter { $0.action != .unchanged }.count
    }

    public var displacementCount: Int {
        steps.filter {
            if case .writeAfterDisplacing = $0.action { return true }
            return false
        }
        .count
    }

    /// What the whole restore needs on disk, which is what the space
    /// check of 11.8 reads.
    public var bytesNeeded: Int64 {
        bytesToWrite + bytesToStage
    }
}

/// The planner of SPEC 11.1, 11.2, and 11.7.
public enum RestorePlanner {

    /// The plan for one snapshot at one scope.
    ///
    /// - `localFiles`: every file under the roots the snapshot
    ///   names, displaced copies included. The copies have to be in
    ///   the list, because a second displacement of one file numbers
    ///   against the names already there.
    /// - `localVersionMarker`: the marker of the local `Game/` tree,
    ///   or `nil` where this device holds no tree.
    /// - `stagedBlobHashes`: the blobs already under `restore/`. A
    ///   restarted run re-verifies them and skips them for free, per
    ///   11.9.
    public static func plan(
        manifest: SnapshotManifest,
        scope: RestoreScope,
        localFiles: [RestoreLocalFile] = [],
        localVersionMarker: SnapshotManifest.VersionMarker? = nil,
        stagedBlobHashes: Set<String> = []
    ) -> RestorePlan {
        var local: [Key: RestoreLocalFile] = [:]
        var taken: [Key: Set<String>] = [:]
        for file in localFiles {
            local[Key(root: file.root, path: file.path)] = file
            taken[directoryKey(root: file.root, path: file.path), default: []]
                .insert(fileName(of: file.path))
        }

        var steps: [RestoreStep] = []
        var blobs: [RestoreBlob] = []
        var seenHashes: Set<String> = []
        var bytesToWrite: Int64 = 0
        var bytesToStage: Int64 = 0
        var partialPaths: [String] = []

        for entry in manifest.entries where scope.covers(entry) {
            let action = decide(
                entry: entry, local: local, taken: &taken)
            steps.append(RestoreStep(entry: entry, action: action))

            guard action != .unchanged else { continue }
            bytesToWrite += entry.size
            if entry.partial { partialPaths.append(entry.path) }
            guard seenHashes.insert(entry.hash).inserted else { continue }
            blobs.append(
                RestoreBlob(
                    hash: entry.hash, compression: entry.compression, sizeBytes: entry.size))
            if !stagedBlobHashes.contains(entry.hash) { bytesToStage += entry.size }
        }

        var showsSheet = false
        if let localVersionMarker {
            showsSheet = VersionMarkerSheet.shows(
                mode: manifest.mode, scope: scope,
                snapshot: manifest.versionMarker, local: localVersionMarker)
        }

        return RestorePlan(
            scope: scope,
            steps: steps,
            blobs: blobs,
            bytesToWrite: bytesToWrite,
            bytesToStage: bytesToStage,
            partialPaths: partialPaths,
            showsVersionMarkerSheet: showsSheet)
    }

    private static func decide(
        entry: SnapshotManifest.Entry,
        local: [Key: RestoreLocalFile],
        taken: inout [Key: Set<String>]
    ) -> RestoreAction {
        guard let here = local[Key(root: entry.root, path: entry.path)] else {
            // Additive. The result is the union, and the user sees
            // nothing, per the second row of 11.2.
            return .write
        }
        if let hash = here.hash, hash == entry.hash {
            // The bytes already match, so the snapshot already wins
            // the name. Displacing here would leave a copy of a file
            // nobody changed, and the user would have to clear it by
            // hand.
            return .unchanged
        }

        let directory = directoryKey(root: entry.root, path: entry.path)
        let name = fileName(of: entry.path)
        let displaced = DisplacedCopy.nextFileName(
            for: name, taken: taken[directory] ?? [])
        taken[directory, default: []].insert(displaced)
        return .writeAfterDisplacing(join(directoryOf(entry.path), displaced))
    }

    // MARK: - Paths

    private struct Key: Hashable {
        var root: EntryRoot
        var path: String
    }

    private static func directoryKey(root: EntryRoot, path: String) -> Key {
        Key(root: root, path: directoryOf(path))
    }

    private static func directoryOf(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    private static func fileName(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }
}

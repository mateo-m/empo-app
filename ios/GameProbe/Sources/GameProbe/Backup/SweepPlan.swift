import Foundation

/// One object of the blob listing, as a provider reports it.
public struct BlobObject: Equatable, Sendable {
    /// The path under the namespace, `blobs/<xx>/<hash>`.
    public let path: String
    /// The object's own modified time, which every v1 provider
    /// reports, per SPEC 5.11.
    public let modifiedAt: Date

    public init(path: String, modifiedAt: Date) {
        self.path = path
        self.modifiedAt = modifiedAt
    }

    /// The hash the path names, or `nil` when the path is not a blob
    /// path.
    public var hash: String? {
        BackupKeys.blobHash(atPath: path)
    }
}

/// The mark-and-sweep of SPEC 5.11, as a pure function.
///
/// Deleting a manifest frees no space, per invariant 1.1.6. Only the
/// sweep deletes blobs:
///
/// - Mark from every manifest in the namespace.
/// - Delete every unreferenced blob older than 7 days, judged by the
///   object's own modified time.
/// - Keep young orphans. A resumed run reuses them for free, and the
///   margin absorbs clock skew and uploads still in flight.
///
/// The clock is a parameter. A `Date()` call inside the function
/// would make the test unrepeatable.
public enum SweepPlan {

    /// How long an unreferenced blob is safe, per 5.11. The margin
    /// absorbs clock skew and uploads still in flight.
    public static let margin: TimeInterval = 7 * 86_400

    /// Every hash the manifests name.
    ///
    /// The reserved chunk list of 5.5 counts as a reference. Version
    /// 1 never writes one, but a marker that ignored it would delete
    /// the blobs of a version it does not understand.
    public static func referencedHashes(
        in manifests: [SnapshotManifest]
    ) -> Set<String> {
        var hashes = Set<String>()
        for manifest in manifests {
            for entry in manifest.entries {
                hashes.insert(entry.hash)
                if let chunks = entry.chunks {
                    hashes.formUnion(chunks)
                }
            }
        }
        return hashes
    }

    /// The blob paths to delete, sorted by path.
    ///
    /// An object whose path names no hash is never deleted. The
    /// sweep cannot tell whether it is referenced, and 5.11 deletes
    /// only what it has proven unreachable.
    public static func blobsToDelete(
        manifests: [SnapshotManifest],
        blobs: [BlobObject],
        now: Date
    ) -> [String] {
        let referenced = referencedHashes(in: manifests)
        return
            blobs
            .filter { blob in
                guard let hash = blob.hash else { return false }
                guard !referenced.contains(hash) else { return false }
                return now.timeIntervalSince(blob.modifiedAt) > margin
            }
            .map(\.path)
            .sorted()
    }
}

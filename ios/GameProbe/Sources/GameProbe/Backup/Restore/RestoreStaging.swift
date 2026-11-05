import Foundation

/// The staged blobs of SPEC 11.9, under `restore/<blob hash>`.
///
/// A restarted run re-verifies what is there and skips it for free,
/// and a cancel keeps the files anyway. The two rules that decide
/// both are here.
public enum RestoreStaging {

    /// Whether a staged blob may be skipped.
    ///
    /// Being there is not enough. The name is the hash of the
    /// content, so the caller verifies the bytes before it skips.
    public static func isStaged(hash: String, staged: Set<String>) -> Bool {
        staged.contains(hash)
    }

    /// Whether the staged bytes hold what the entry names.
    ///
    /// A `stored` blob is the content, so a caller with a large file
    /// hashes it from disk instead and never reads it into memory. A
    /// `zlib` blob is under the 32 MB limit of 6.4, so one of them in
    /// memory is the peak cost.
    public static func holds(_ bytes: Data, entry: SnapshotManifest.Entry) -> Bool {
        guard
            let decoded = try? BlobCodec.decode(
                bytes, algorithm: entry.compression, maxBytes: inflatedSizeLimit(of: entry))
        else { return false }
        return ContentHash.hex(of: decoded) == entry.hash
    }

    /// The bytes of a staged `zlib` blob, or nil for a damaged one.
    ///
    /// `BlobCodec.encode` keeps a zlib blob only when it is smaller
    /// than its content, so a staged file of that size or more is
    /// damaged. The check runs before the read, so such a file never
    /// enters memory.
    public static func zlibBytes(at file: URL, entry: SnapshotManifest.Entry) -> Data? {
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size])
                as? Int,
            size < inflatedSizeLimit(of: entry)
        else { return nil }
        return try? Data(contentsOf: file)
    }

    /// The manifest comes from the storage service, so its size alone
    /// does not bound the memory. A run compresses no file over the
    /// compression limit.
    public static func inflatedSizeLimit(of entry: SnapshotManifest.Entry) -> Int {
        Int(clamping: min(entry.size, SnapshotEngine.compressionSizeLimit))
    }

    /// The blobs a plan still has to fetch, given what is staged.
    public static func toFetch(_ blobs: [RestoreBlob], staged: Set<String>) -> [RestoreBlob] {
        blobs.filter { !isStaged(hash: $0.hash, staged: staged) }
    }
}

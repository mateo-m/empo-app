import Foundation
import GameProbe

/// Where an S3 multipart upload waits out an app termination, per
/// SPEC 9.4.
///
/// One JSON file holds every upload in flight, keyed by the object
/// key. It sits in the outbox, beside the blob files an upload
/// already works from, so a delete of the local root of 6.1 takes it
/// too.
///
/// The record matters more here than on Dropbox or on Drive. Those
/// two drop a dead session by themselves. S3 keeps the parts of an
/// abandoned upload and bills the user for them, so the upload id has
/// to survive a termination. `AbortMultipartUpload` needs it.
///
/// This is the store ticket 009 wrote for Drive, with the record S3
/// needs.
actor S3MultipartStore {

    static let shared = S3MultipartStore()

    static let fileName = "s3-multipart-uploads.json"

    private var records: [String: S3MultipartUpload]?

    private init() {}

    private var file: URL {
        BackupRoot.outbox.appendingPathComponent(Self.fileName)
    }

    /// The upload to carry on from, or `nil` to open a new one.
    func upload(
        forKey key: String, fileSize: Int64, now: Date = Date()
    ) -> S3MultipartUpload? {
        guard let record = load()[key] else { return nil }
        guard record.isUsable(at: now, forFileOfSize: fileSize) else {
            forget(key: key)
            return nil
        }
        return record
    }

    /// Writes the parts after one lands. The next launch reads them.
    func remember(_ record: S3MultipartUpload) {
        var records = load()
        records[record.key] = record
        save(records)
    }

    func forget(key: String) {
        var records = load()
        guard records.removeValue(forKey: key) != nil else { return }
        save(records)
    }

    // MARK: - The file

    private func load() -> [String: S3MultipartUpload] {
        if let records { return records }
        let data = (try? Data(contentsOf: file)) ?? Data()
        let records = try? JSONDecoder().decode([String: S3MultipartUpload].self, from: data)
        self.records = records ?? [:]
        return self.records ?? [:]
    }

    private func save(_ records: [String: S3MultipartUpload]) {
        self.records = records
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        // Atomic, so a termination mid-write leaves the older record
        // and never a torn file. An older record costs one part.
        try? data.write(to: file, options: .atomic)
    }
}

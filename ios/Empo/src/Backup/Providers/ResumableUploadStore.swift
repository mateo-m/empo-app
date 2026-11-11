import Foundation
import GameProbe

/// Where an upload in flight waits out an app termination, per SPEC
/// 9.2, 9.3, and 9.4.
///
/// One JSON file per service holds every upload in flight. It sits in
/// the outbox, beside the blob files an upload already works from, so
/// a delete of the local root of 6.1 takes it too.
///
/// Two targets can hold the same path in different accounts or
/// buckets, so a record belongs to one target and one path.
actor ResumableUploadStore<Record: ResumableUpload> {

    private let fileName: String
    private var records: [String: Record]?

    init(fileName: String) {
        self.fileName = fileName
    }

    private var file: URL {
        BackupRoot.layout.outbox.appendingPathComponent(fileName)
    }

    /// The upload to carry on from, or `nil` to start a new one.
    func record(
        targetId: String, path: String, fileSize: Int64, now: Date = Date()
    ) -> Record? {
        guard let record = load()[Self.key(targetId, path)] else { return nil }
        // Another path, such as the sync document, can hold new bytes
        // of the same size at the next launch, and a resume would join
        // the two versions.
        guard BackupKeys.endsInBlobPath(path), record.isUsable(at: now, forFileOfSize: fileSize)
        else {
            forget(targetId: targetId, path: path)
            return nil
        }
        return record
    }

    /// The record as it is on disk, also one that `record` would drop.
    func stored(targetId: String, path: String) -> Record? {
        load()[Self.key(targetId, path)]
    }

    /// Writes the cursor after a chunk lands. The next launch reads it.
    func remember(_ record: Record, targetId: String, path: String) {
        var records = load()
        records[Self.key(targetId, path)] = record
        save(records)
    }

    func forget(targetId: String, path: String) {
        var records = load()
        guard records.removeValue(forKey: Self.key(targetId, path)) != nil else { return }
        save(records)
    }

    private static func key(_ targetId: String, _ path: String) -> String {
        targetId + "\n" + path
    }

    // MARK: - The file

    private func load() -> [String: Record] {
        if let records { return records }
        let data = (try? Data(contentsOf: file)) ?? Data()
        let records = (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
        self.records = records
        return records
    }

    private func save(_ records: [String: Record]) {
        self.records = records
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        // Atomic, so a termination mid-write leaves the older cursor
        // and never a torn file. An older cursor costs one chunk.
        try? data.write(to: file, options: .atomic)
    }
}

let dropboxUploadSessions = ResumableUploadStore<DropboxUploadSession>(
    fileName: "dropbox-upload-sessions.json")
let googleDriveUploadSessions = ResumableUploadStore<GoogleDriveUploadSession>(
    fileName: "google-drive-upload-sessions.json")
/// S3 keeps the parts of an abandoned upload and bills the user for
/// them, so the upload id must survive a termination for
/// `AbortMultipartUpload`.
let s3MultipartUploads = ResumableUploadStore<S3MultipartUpload>(
    fileName: "s3-multipart-uploads.json")

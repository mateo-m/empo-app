import Foundation
import GameProbe

/// Where a Google Drive resumable session waits out an app
/// termination, per SPEC 9.3.
///
/// One JSON file holds every session in flight, keyed by the remote
/// path. It sits in the outbox, beside the blob files an upload
/// already works from, so a delete of the local root of 6.1 takes it
/// too. That is right: the root holds nothing but rebuildable work.
///
/// The file is small. Four transfers run per target, per 8.6, so it
/// holds four records at the most.
///
/// This is the store ticket 009 wrote for Dropbox, with the record
/// Drive needs. The two services name a session differently, so each
/// keeps its own file.
actor GoogleDriveUploadSessionStore {

    static let shared = GoogleDriveUploadSessionStore()

    static let fileName = "google-drive-upload-sessions.json"

    private var records: [String: GoogleDriveUploadSession]?

    private init() {}

    private var file: URL {
        BackupRoot.outbox.appendingPathComponent(Self.fileName)
    }

    /// The session to carry on from, or `nil` to start a new one.
    func session(
        forPath path: String, fileSize: Int64, now: Date = Date()
    ) -> GoogleDriveUploadSession? {
        guard let record = load()[path] else { return nil }
        guard record.isUsable(at: now, forFileOfSize: fileSize) else {
            forget(path: path)
            return nil
        }
        return record
    }

    /// Writes the cursor after a chunk lands. The next launch reads it.
    func remember(_ session: GoogleDriveUploadSession, forPath path: String) {
        var records = load()
        records[path] = session
        save(records)
    }

    func forget(path: String) {
        var records = load()
        guard records.removeValue(forKey: path) != nil else { return }
        save(records)
    }

    // MARK: - The file

    private func load() -> [String: GoogleDriveUploadSession] {
        if let records { return records }
        let data = (try? Data(contentsOf: file)) ?? Data()
        let records = try? JSONDecoder().decode(
            [String: GoogleDriveUploadSession].self, from: data)
        self.records = records ?? [:]
        return self.records ?? [:]
    }

    private func save(_ records: [String: GoogleDriveUploadSession]) {
        self.records = records
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        // Atomic, so a termination mid-write leaves the older cursor
        // and never a torn file. An older cursor costs one chunk.
        try? data.write(to: file, options: .atomic)
    }
}

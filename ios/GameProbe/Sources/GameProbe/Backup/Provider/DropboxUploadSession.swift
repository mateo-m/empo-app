import Foundation

/// One Dropbox upload session that outlived the process, per SPEC 9.2.
///
/// A file over 150 MiB uploads in 16 MiB chunks, and each chunk needs
/// the app to run code. iOS ends a suspended app whenever it wants, so
/// a chunked upload that keeps its session in memory alone restarts
/// from byte 0 at the next launch. A large game on a device that
/// reclaims Empo then never finishes.
///
/// 9.2 states that a session stays valid for 7 days. This record is
/// what makes that sentence worth anything: the session id and the
/// offset go to disk after every chunk, and the next `put` of the same
/// path carries on where the last one stopped.
public struct DropboxUploadSession: Codable, Equatable, Sendable {

    /// What `upload_session/start` answered.
    public var sessionId: String
    /// How many bytes Dropbox has taken. The next chunk starts here.
    public var offset: Int64
    /// The size of the file this session uploads. A file of another
    /// size at the same path is another upload.
    public var fileSize: Int64
    /// When `upload_session/start` answered.
    public var startedAt: Date

    /// How long Dropbox keeps a session, per 9.2.
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    public init(sessionId: String, offset: Int64, fileSize: Int64, startedAt: Date) {
        self.sessionId = sessionId
        self.offset = offset
        self.fileSize = fileSize
        self.startedAt = startedAt
    }

    /// Whether a later `put` may carry on from this record.
    ///
    /// Four things have to hold. The session id has to be there, the
    /// file has to be the same size, the offset has to name real work
    /// that is not yet finished, and the session has to be inside the
    /// 7 days of 9.2. A record that fails any of them is dead weight,
    /// and the caller starts a new session.
    public func isUsable(at now: Date, forFileOfSize size: Int64) -> Bool {
        guard !sessionId.isEmpty else { return false }
        guard fileSize == size else { return false }
        guard offset > 0, offset < size else { return false }
        return now.timeIntervalSince(startedAt) < Self.lifetime
    }

    /// Whether Dropbox says the session itself is gone.
    ///
    /// `incorrect_offset` is not in this set. It carries
    /// `correct_offset`, so the session lives and only the cursor was
    /// wrong, and `Dropbox.correctedOffset(inBody:)` reads it.
    public static func isDead(errorSummary: String) -> Bool {
        let summary = errorSummary.lowercased()
        return summary.contains("not_found") || summary.contains("closed")
    }
}

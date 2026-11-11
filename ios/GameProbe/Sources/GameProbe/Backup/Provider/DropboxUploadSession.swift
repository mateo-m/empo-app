import Foundation

public struct DropboxUploadSession: ResumableUpload, Equatable {

    /// What `upload_session/start` answered.
    public var sessionId: String
    /// How many bytes Dropbox has taken. The next chunk starts here.
    public var offset: Int64
    public var fileSize: Int64
    /// When `upload_session/start` answered.
    public var startedAt: Date

    public init(sessionId: String, offset: Int64, fileSize: Int64, startedAt: Date) {
        self.sessionId = sessionId
        self.offset = offset
        self.fileSize = fileSize
        self.startedAt = startedAt
    }

    /// A record at the end of the file skips to `finish`, because the process can end after the
    /// last chunk and before the commit.
    public func hasCursor(forFileOfSize size: Int64) -> Bool {
        !sessionId.isEmpty && offset > 0 && offset <= size
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

    /// Whether a failed `finish` leaves a cursor no later run can use.
    /// Dropbox puts every cursor fault of `finish` under
    /// `lookup_failed`, `incorrect_offset` included.
    public static func finishLostTheCursor(errorSummary: String) -> Bool {
        isDead(errorSummary: errorSummary) || errorSummary.lowercased().contains("lookup_failed")
    }
}

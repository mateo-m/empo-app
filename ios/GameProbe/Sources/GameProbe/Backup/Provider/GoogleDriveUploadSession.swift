import Foundation

/// One Google Drive resumable session that outlived the process, per
/// SPEC 9.3.
///
/// A file over 5 MB uploads in chunks, and each chunk needs the app
/// to run code. iOS ends a suspended app whenever it wants, so a
/// chunked upload that keeps its session URI in memory alone starts
/// again from byte 0 at the next launch. A large game on a device
/// that reclaims Empo then never finishes.
///
/// 9.3 states that a session URI expires after one week. This record
/// is what makes that sentence worth anything: the URI and the offset
/// go to disk after every chunk, and the next `put` of the same path
/// carries on where the last one stopped.
///
/// This is the same rule ticket 009 wrote for Dropbox. Drive names
/// its session with a URI rather than an id, so the record differs in
/// that one field.
public struct GoogleDriveUploadSession: Codable, Equatable, Sendable {

    /// The session URI Drive answered in its `Location` header.
    public var sessionURI: String
    /// How many bytes Drive has taken. The next chunk starts here.
    public var offset: Int64
    /// The size of the file this session uploads. A file of another
    /// size at the same path is another upload.
    public var fileSize: Int64
    /// When Drive answered the session URI.
    public var startedAt: Date

    /// How long Drive keeps a session URI, per 9.3.
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    public init(sessionURI: String, offset: Int64, fileSize: Int64, startedAt: Date) {
        self.sessionURI = sessionURI
        self.offset = offset
        self.fileSize = fileSize
        self.startedAt = startedAt
    }

    /// Whether a later `put` may carry on from this record.
    ///
    /// Four things have to hold. The URI has to be there, the file
    /// has to be the same size, the offset has to name real work that
    /// is not yet finished, and the session has to be inside the week
    /// of 9.3. A record that fails any of them is dead weight, and
    /// the caller starts a new session.
    public func isUsable(at now: Date, forFileOfSize size: Int64) -> Bool {
        guard !sessionURI.isEmpty else { return false }
        guard fileSize == size else { return false }
        guard offset > 0, offset < size else { return false }
        return now.timeIntervalSince(startedAt) < Self.lifetime
    }
}

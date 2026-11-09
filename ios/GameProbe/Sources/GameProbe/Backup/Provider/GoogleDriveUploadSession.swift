import Foundation

public struct GoogleDriveUploadSession: ResumableUpload, Equatable {

    /// The session URI Drive answered in its `Location` header.
    public var sessionURI: String
    /// How many bytes Drive has taken. The next chunk starts here.
    public var offset: Int64
    public var fileSize: Int64
    /// When Drive answered the session URI.
    public var startedAt: Date

    public init(sessionURI: String, offset: Int64, fileSize: Int64, startedAt: Date) {
        self.sessionURI = sessionURI
        self.offset = offset
        self.fileSize = fileSize
        self.startedAt = startedAt
    }

    /// Drive makes the file with the last chunk, so a record at the end of the file has no work
    /// left.
    public func hasCursor(forFileOfSize size: Int64) -> Bool {
        !sessionURI.isEmpty && offset > 0 && offset < size
    }
}

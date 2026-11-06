import Foundation

/// One multipart upload that outlived the process, per SPEC 9.4.
///
/// A file over 5 GiB goes up in parts, and each part needs the app to
/// run code. iOS ends a suspended app whenever it wants, so an upload
/// that keeps its id in memory alone starts again from part 1 at the
/// next launch.
///
/// The record is worth more here than on the OAuth services, because
/// an abandoned multipart upload leaves parts on the service and
/// parts cost money, per 9.4. The id on disk is what lets the next
/// run carry on, and, where it cannot, abort what the last run left.
///
/// This is the same rule ticket 009 wrote for Dropbox and ticket 010
/// wrote for Google Drive. S3 names an upload with an id and numbers
/// its parts, so the record carries both.
public struct S3MultipartUpload: Codable, Equatable, Sendable {

    /// The id `CreateMultipartUpload` answered.
    public var uploadId: String
    /// The key this upload writes.
    public var key: String
    /// The size of the file. A file of another size at the same key
    /// is another upload.
    public var fileSize: Int64
    /// What one part holds. A resumed run keeps it, because a part
    /// of another size would not line up with the parts already
    /// there.
    public var partSize: Int64
    /// The parts the service has taken, with the tag it answered.
    public var parts: [S3.CompletedPart]
    /// When the service answered the id.
    public var startedAt: Date

    /// How long Empo carries on from a record.
    ///
    /// The service keeps a multipart upload until someone aborts it
    /// or a rule of the bucket removes it, so nothing forces this
    /// number. 7 days is the life of a presigned URL in 9.4, and a
    /// run that has not finished in a week is a run that failed.
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    public init(
        uploadId: String,
        key: String,
        fileSize: Int64,
        partSize: Int64,
        parts: [S3.CompletedPart] = [],
        startedAt: Date
    ) {
        self.uploadId = uploadId
        self.key = key
        self.fileSize = fileSize
        self.partSize = partSize
        self.parts = parts
        self.startedAt = startedAt
    }

    /// Whether a later `put` may carry on from this record.
    ///
    /// The id has to be there, the file has to be the same size, and
    /// the record has to be inside the week. A record that fails any
    /// of them is dead weight, and the caller aborts it and starts a
    /// new upload.
    public func isUsable(at now: Date, forFileOfSize size: Int64) -> Bool {
        guard !uploadId.isEmpty else { return false }
        guard fileSize == size, partSize > 0 else { return false }
        return now.timeIntervalSince(startedAt) < Self.lifetime
    }

    /// The tag of one part, or `nil` where the service does not hold
    /// it yet.
    public func eTag(ofPart number: Int) -> String? {
        parts.first { $0.number == number }?.eTag
    }

    /// The same record with one more part taken.
    public func adding(_ part: S3.CompletedPart) -> S3MultipartUpload {
        var copy = self
        copy.parts.removeAll { $0.number == part.number }
        copy.parts.append(part)
        copy.parts.sort { $0.number < $1.number }
        return copy
    }

    /// The same record with the parts the service reports, which is
    /// what a resumed run reads before it sends a byte.
    ///
    /// The service is the truth. A part the record names and the
    /// service does not hold goes up again, and a part the service
    /// holds and the record does not is taken as it is.
    public func matching(_ found: [S3.CompletedPart]) -> S3MultipartUpload {
        var copy = self
        copy.parts = found.sorted { $0.number < $1.number }
        return copy
    }
}

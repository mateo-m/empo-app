import Foundation

/// A multipart upload that S3 never finishes leaves parts on the service, and parts cost money, per
/// SPEC 9.4. The id on disk lets the next run carry on or abort what the last run left.
public struct S3MultipartUpload: ResumableUpload, Equatable {

    /// The id `CreateMultipartUpload` answered.
    public var uploadId: String
    /// The key this upload writes.
    public var key: String
    public var fileSize: Int64
    /// What one part holds. A resumed run keeps it, because a part
    /// of another size would not line up with the parts already
    /// there.
    public var partSize: Int64
    /// The parts the service has taken, with the tag it answered.
    public var parts: [S3.CompletedPart]
    /// When the service answered the id.
    public var startedAt: Date

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

    public func hasCursor(forFileOfSize size: Int64) -> Bool {
        !uploadId.isEmpty && partSize > 0
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

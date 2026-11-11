import Foundation

/// An upload record that a later launch may carry on from, per SPEC 9.2, 9.3, and 9.4.
///
/// iOS ends a suspended app whenever it wants. Without a record on disk, a chunked upload starts
/// again from byte 0 at the next launch, and a large game never finishes.
public protocol ResumableUpload: Codable, Sendable {
    var fileSize: Int64 { get }
    var startedAt: Date { get }
    func hasCursor(forFileOfSize size: Int64) -> Bool
}

extension ResumableUpload {

    /// Dropbox and Drive keep a session 7 days. S3 keeps an upload until an abort, and 7 days is
    /// the life of a presigned URL there.
    public static var lifetime: TimeInterval { 7 * .day }

    /// A file of another size at the same path is another upload.
    public func isUsable(at now: Date, forFileOfSize size: Int64) -> Bool {
        fileSize == size && hasCursor(forFileOfSize: size)
            && now.timeIntervalSince(startedAt) < Self.lifetime
    }
}

import Foundation

/// One chunk of a Dropbox upload session or a Drive resumable upload.
public struct UploadChunk: Equatable, Sendable {
    public let offset: Int64
    public let length: Int64
    /// The service commits the file after the last chunk, which is how a chunked upload meets the
    /// atomicity promise of 8.2.
    public let isLast: Bool

    public init(offset: Int64, length: Int64, isLast: Bool) {
        self.offset = offset
        self.length = length
        self.isLast = isLast
    }

    public var endOffset: Int64 { offset + length }

    /// A broken upload carries on from the offset the service reports, so it never starts again
    /// from zero. An offset at the end of the file leaves no chunk.
    public static func plan(fileSize size: Int64, from offset: Int64, chunkBytes: Int64) -> [UploadChunk] {
        var chunks: [UploadChunk] = []
        var cursor = max(0, min(offset, size))
        while cursor < size {
            let length = min(chunkBytes, size - cursor)
            cursor += length
            chunks.append(UploadChunk(offset: cursor - length, length: length, isLast: cursor >= size))
        }
        return chunks
    }
}

import Foundation
import GameProbe

/// The disk work every provider does before a background upload.
///
/// A background URLSession uploads from a file and from nothing
/// else, so a chunk, a part, and a multipart body all go to disk
/// first.
enum UploadStaging {

    /// How much of a file one read holds. A chunk is up to 16 MiB
    /// and a part is tens of megabytes, so neither one sits in
    /// memory whole.
    private static let readSize = 1024 * 1024

    static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// A directory of this provider's own, for the pieces of one
    /// upload.
    static func scratchDirectory(_ provider: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("empo-\(provider)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies one byte range of a file into a file of its own.
    static func piece(
        of localFile: URL, offset: Int64, length: Int64, named name: String, in scratch: URL
    ) throws(BackupProviderError) -> URL {
        let url = scratch.appendingPathComponent(name)
        do {
            let source = try FileHandle(forReadingFrom: localFile)
            defer { try? source.close() }
            try source.seek(toOffset: UInt64(offset))

            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let piece = try FileHandle(forWritingTo: url)
            defer { try? piece.close() }

            var left = length
            while left > 0 {
                let want = Int(min(left, Int64(readSize)))
                guard let bytes = try source.read(upToCount: want), !bytes.isEmpty else { break }
                try piece.write(contentsOf: bytes)
                left -= Int64(bytes.count)
            }
        } catch {
            throw stagingFailure(error)
        }
        return url
    }

    /// Writes a header, a whole file, and a trailer into one file.
    static func write(
        head: Data, contentsOf content: URL, tail: Data, to url: URL
    ) throws(BackupProviderError) {
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: head) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let body = try FileHandle(forWritingTo: url)
            defer { try? body.close() }
            try body.seekToEnd()

            let source = try FileHandle(forReadingFrom: content)
            defer { try? source.close() }
            while let bytes = try source.read(upToCount: readSize), !bytes.isEmpty {
                try body.write(contentsOf: bytes)
            }
            try body.write(contentsOf: tail)
        } catch {
            throw stagingFailure(error)
        }
    }

    private static func stagingFailure(_ error: Error) -> BackupProviderError {
        .rejected(message: "this device could not stage the upload: \(error.localizedDescription)")
    }
}

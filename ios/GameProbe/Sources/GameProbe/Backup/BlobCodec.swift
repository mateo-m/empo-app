import Foundation

#if canImport(Compression)
import Compression
#else
import SWCompression
#endif

/// How one blob is stored, recorded per entry in the manifest, per
/// SPEC 5.6.
///
/// The choice is per blob because full-mode trees are mostly
/// already-compressed assets, while saves are Marshal blobs that
/// deflate well.
public enum BlobCompression: String, Codable, Sendable, CaseIterable, Equatable {
    /// The bytes are the file's bytes.
    case stored
    /// The bytes are a zlib stream, per RFC 1950.
    case zlib
}

/// Compresses and decompresses one blob, per SPEC 5.6.
///
/// `encode` compresses the bytes and keeps whichever result is
/// smaller. The caller records `algorithm` in the manifest entry.
///
/// Apple platforms frame the stream here, by hand. Apple's
/// Compression framework with `COMPRESSION_ZLIB` reads and writes raw
/// DEFLATE. It writes no 2-byte header and no trailing Adler-32.
/// `ZlibInflate.swift` already strips that header on the reading
/// side. Section 5.6 chose zlib so a desktop tool can read a
/// namespace, so raw DEFLATE fails the rule on the writing side.
/// This file therefore writes the header, then the DEFLATE body from
/// Compression, then the Adler-32 of the uncompressed bytes. It adds
/// no dependency. A C system-library target over `zlib.h` does the
/// same job, but it adds a target and a module map to every platform
/// for 30 lines of framing.
///
/// Linux has no Compression framework, so it calls SWCompression,
/// which writes and checks the frame itself. `ZlibInflate.swift`
/// already calls SWCompression for the same job.
public enum BlobCodec {

    public struct Encoded: Equatable, Sendable {
        public let algorithm: BlobCompression
        public let bytes: Data

        public init(algorithm: BlobCompression, bytes: Data) {
            self.algorithm = algorithm
            self.bytes = bytes
        }
    }

    public enum Failure: Error, Equatable {
        /// The bytes are not a zlib stream this reader can inflate.
        case corruptZlibStream
        /// The stream inflated, but its Adler-32 does not match.
        case checksumMismatch
    }

    /// Compresses `data` and keeps whichever result is smaller.
    public static func encode(_ data: Data) -> Encoded {
        guard let framed = zlibCompress(data), framed.count < data.count else {
            return Encoded(algorithm: .stored, bytes: data)
        }
        return Encoded(algorithm: .zlib, bytes: framed)
    }

    /// Always compresses, whatever the size. Manifests take this
    /// path, per 5.6.
    public static func encodeZlib(_ data: Data) throws -> Data {
        guard let framed = zlibCompress(data) else {
            throw Failure.corruptZlibStream
        }
        return framed
    }

    public static func decode(_ bytes: Data, algorithm: BlobCompression) throws -> Data {
        switch algorithm {
        case .stored:
            return bytes
        case .zlib:
            return try zlibDecompress(bytes)
        }
    }

    /// The zlib stream of no bytes: the header, one empty block that
    /// closes the stream, then the Adler-32 of nothing, which is 1.
    /// The platform writers report no output for an empty input, so
    /// this constant answers for both.
    private static let emptyZlibStream = Data([
        0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01,
    ])

    private static func zlibCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return emptyZlibStream }
        return platformZlibCompress(data)
    }

    // MARK: - Adler-32, per RFC 1950

    /// The block length is zlib's own `NMAX`: the largest run that
    /// cannot overflow a 32-bit sum before the modulo.
    private static let adlerBlockLength = 5552
    private static let adlerModulus: UInt32 = 65_521

    static func adler32(_ data: Data) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var index = 0
            while index < raw.count {
                let blockEnd = min(index + adlerBlockLength, raw.count)
                while index < blockEnd {
                    low &+= UInt32(raw[index])
                    high &+= low
                    index += 1
                }
                low %= adlerModulus
                high %= adlerModulus
            }
        }
        return (high << 16) | low
    }

    #if canImport(Compression)

    /// CM 8 (DEFLATE) with a 32K window, then FLEVEL 2 (the default
    /// level) and no preset dictionary. `0x789C` is a multiple of 31,
    /// which is the header check of RFC 1950.
    private static let zlibHeader: [UInt8] = [0x78, 0x9C]

    private static func platformZlibCompress(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 8 + 1_024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return compression_encode_buffer(
                destination, capacity, source, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }

        var out = Data(zlibHeader)
        out.append(destination, count: written)
        let checksum = adler32(data)
        out.append(contentsOf: [
            UInt8(truncatingIfNeeded: checksum >> 24),
            UInt8(truncatingIfNeeded: checksum >> 16),
            UInt8(truncatingIfNeeded: checksum >> 8),
            UInt8(truncatingIfNeeded: checksum),
        ])
        return out
    }

    private static func zlibDecompress(_ bytes: Data) throws -> Data {
        let frame = Data(bytes)
        guard frame.count >= 6 else { throw Failure.corruptZlibStream }
        let method = frame[frame.startIndex]
        let flags = frame[frame.startIndex + 1]
        guard method & 0x0F == 8 else { throw Failure.corruptZlibStream }
        guard flags & 0x20 == 0 else { throw Failure.corruptZlibStream }
        guard (UInt16(method) << 8 | UInt16(flags)) % 31 == 0 else {
            throw Failure.corruptZlibStream
        }

        let body = Data(frame.dropFirst(2).dropLast(4))
        let out = try inflateRawDeflate(body)

        let tail = frame.suffix(4)
        var expected: UInt32 = 0
        for byte in tail { expected = expected << 8 | UInt32(byte) }
        guard adler32(out) == expected else { throw Failure.checksumMismatch }
        return out
    }

    /// Inflates a raw DEFLATE body through the streaming API, so the
    /// output size does not have to be guessed up front.
    private static func inflateRawDeflate(_ body: Data) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard
            compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else { throw Failure.corruptZlibStream }
        defer { compression_stream_destroy(stream) }

        let bufferSize = 64 * 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var out = Data()
        try body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw Failure.corruptZlibStream
            }
            stream.pointee.src_ptr = source
            stream.pointee.src_size = body.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(
                    stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.pointee.dst_size
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END
                else { throw Failure.corruptZlibStream }
                if produced > 0 { out.append(buffer, count: produced) }
                if status == COMPRESSION_STATUS_END { return }
                // No input left and no output made: the stream ended
                // early. Without this the loop would never finish.
                guard produced > 0 || stream.pointee.src_size > 0 else {
                    throw Failure.corruptZlibStream
                }
            }
        }
        return out
    }

    #else

    private static func platformZlibCompress(_ data: Data) -> Data? {
        ZlibArchive.archive(data: data)
    }

    private static func zlibDecompress(_ bytes: Data) throws -> Data {
        do {
            return try ZlibArchive.unarchive(archive: Data(bytes))
        } catch let error as ZlibError {
            if case .wrongAdler32 = error { throw Failure.checksumMismatch }
            throw Failure.corruptZlibStream
        } catch {
            throw Failure.corruptZlibStream
        }
    }

    #endif
}

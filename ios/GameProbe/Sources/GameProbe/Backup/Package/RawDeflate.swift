import Foundation

#if canImport(Compression)
import Compression
#else
import SWCompression
#endif

/// Raw DEFLATE and CRC-32, which is what a ZIP entry needs.
///
/// `BlobCodec` writes a zlib frame around the same DEFLATE body,
/// because SPEC 5.6 wants a frame a desktop tool reads. A ZIP entry
/// carries the body alone plus a CRC-32 in its own header, so the
/// two cannot share one function.
///
/// Apple platforms compress a stream of any size. Linux compresses
/// one buffer, so `ZipWriter` stores a large entry there instead.
/// Only iOS writes a package, and only Apple platforms hold the
/// multi-gigabyte games this rule is about.
enum RawDeflate {

    /// The largest entry a whole-buffer platform compresses.
    static let bufferLimit = 32 * 1_024 * 1_024

    static var compressesAStream: Bool {
        #if canImport(Compression)
        return true
        #else
        return false
        #endif
    }

    // MARK: - CRC-32, per the ZIP appnote

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    static func crc32(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var value = ~seed
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                value = (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 0xFF)]
            }
        }
        return ~value
    }

    // MARK: - Whole buffers

    #if canImport(Compression)

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
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
        return Data(bytes: destination, count: written)
    }

    #else

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        return Deflate.compress(data: data)
    }

    static func inflate(_ body: Data) throws -> Data {
        try Deflate.decompress(data: body)
    }

    #endif
}

#if canImport(Compression)

/// One DEFLATE stream, fed chunk by chunk.
///
/// The whole-buffer call needs the whole file in memory, and a
/// package holds files of any size, so a package entry goes through
/// this instead.
final class DeflateStream {

    private let stream: UnsafeMutablePointer<compression_stream>
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 256 * 1_024
    private var closed = false

    static func encoder() -> DeflateStream? { DeflateStream(COMPRESSION_STREAM_ENCODE) }
    static func decoder() -> DeflateStream? { DeflateStream(COMPRESSION_STREAM_DECODE) }

    private init?(_ operation: compression_stream_operation) {
        stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        guard
            compression_stream_init(stream, operation, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else {
            stream.deallocate()
            return nil
        }
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    }

    deinit {
        if !closed { compression_stream_destroy(stream) }
        stream.deallocate()
        buffer.deallocate()
    }

    /// The output this chunk produced, which may be empty.
    func push(_ chunk: Data) -> Data? {
        process(chunk, flags: 0)
    }

    /// The output left after the last chunk. The stream is done
    /// after this call.
    func finish() -> Data? {
        defer {
            compression_stream_destroy(stream)
            closed = true
        }
        return process(Data(), flags: Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
    }

    private func process(_ chunk: Data, flags: Int32) -> Data? {
        var out = Data()
        var failed = false
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.pointee.src_ptr =
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                ?? UnsafePointer(buffer)
            stream.pointee.src_size = chunk.count
            repeat {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, flags)
                guard status != COMPRESSION_STATUS_ERROR else {
                    failed = true
                    return
                }
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 { out.append(buffer, count: produced) }
                if status == COMPRESSION_STATUS_END { return }
                if stream.pointee.src_size == 0 && produced == 0 { return }
            } while true
        }
        return failed ? nil : out
    }
}

#endif

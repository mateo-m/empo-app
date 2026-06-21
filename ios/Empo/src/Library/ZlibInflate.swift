import Foundation

#if canImport(Compression)
import Compression

enum ZlibInflate {
    /// Zlib payload with 2-byte header stripped; body is raw deflate.
    static func inflateSkippingZlibHeader(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let raw = data.dropFirst(2)
        let bufferSize = max(raw.count * 16, 65_536)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }
        let written = raw.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) -> Int in
            guard let base = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return compression_decode_buffer(
                dst, bufferSize, base, raw.count, nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return Data(bytes: dst, count: written)
    }
}

#else
import SWCompression

enum ZlibInflate {
    static func inflateSkippingZlibHeader(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let raw = Data(data.dropFirst(2))
        return try? Deflate.decompress(data: raw)
    }
}

#endif

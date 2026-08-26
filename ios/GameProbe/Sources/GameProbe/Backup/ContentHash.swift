import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// SHA-256 over bytes and over files, for the on-target format of
/// SPEC section 5.6.
///
/// CryptoKit is in the OS on Apple platforms. Linux gets the same
/// API from `apple/swift-crypto`, added to `Package.swift` the way
/// SWCompression is, with `condition: .when(platforms: [.linux])`.
///
/// `format.json` records the function by name, per 5.6 and 15.3, so
/// a later keyed hash is a new name plus a new format version. Read
/// the name from the descriptor. Do not assume it.
public enum ContentHash {

    /// The name `format.json` records for this function.
    public static let functionName = "sha-256"

    /// How many bytes `hexOfFile` reads at a time. The hash of a
    /// 4 GB file therefore costs 1 MB of memory.
    public static let chunkSize = 1 << 20

    public enum Failure: Error, Equatable {
        case cannotReadFile(path: String)
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func hex(of data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    /// Lowercase hex SHA-256 of the UTF-8 bytes of `text`.
    public static func hex(ofUTF8 text: String) -> String {
        hex(of: Data(text.utf8))
    }

    /// Lowercase hex SHA-256 of the file at `url`, read in chunks so
    /// the memory cost does not follow the file size.
    public static func hexOfFile(at url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure.cannotReadFile(path: url.path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw Failure.cannotReadFile(path: url.path)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }

    private static func hexString(_ digest: SHA256Digest) -> String {
        var out = ""
        out.reserveCapacity(SHA256Digest.byteCount * 2)
        for byte in digest {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }

    private static let hexDigits = Array("0123456789abcdef")
}

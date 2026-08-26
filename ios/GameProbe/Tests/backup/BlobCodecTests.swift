import Foundation
import XCTest

@testable import GameProbe

final class BlobCodecTests: XCTestCase {

    // MARK: - A plain zlib reader, written here on purpose

    /// Reads an RFC 1950 stream the way a desktop tool would: the
    /// 2-byte header, the raw DEFLATE body, then the Adler-32 of the
    /// inflated bytes. The Adler-32 loop is written out here so the
    /// check shares no code with the writer.
    private func inflateWithAPlainZlibReader(
        _ frame: Data, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Data {
        let bytes = [UInt8](frame)
        XCTAssertGreaterThanOrEqual(bytes.count, 6, file: file, line: line)

        let method = bytes[0]
        let flags = bytes[1]
        XCTAssertEqual(method & 0x0F, 8, "not DEFLATE", file: file, line: line)
        XCTAssertEqual(method >> 4, 7, "not a 32K window", file: file, line: line)
        XCTAssertEqual(flags & 0x20, 0, "a preset dictionary", file: file, line: line)
        XCTAssertEqual(
            (UInt16(method) << 8 | UInt16(flags)) % 31, 0, "bad header check",
            file: file, line: line)

        guard
            let body = ZlibInflate.inflateSkippingZlibHeader(
                Data(bytes.dropLast(4)))
        else {
            XCTFail("the body did not inflate", file: file, line: line)
            return Data()
        }

        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in body {
            low = (low + UInt32(byte)) % 65_521
            high = (high + low) % 65_521
        }
        var trailer: UInt32 = 0
        for byte in bytes.suffix(4) { trailer = trailer << 8 | UInt32(byte) }
        XCTAssertEqual(trailer, (high << 16) | low, "bad Adler-32", file: file, line: line)

        return body
    }

    /// Bytes that do not compress, from a repeatable sequence.
    private func incompressibleBytes(count: Int) -> Data {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var out = Data()
        out.reserveCapacity(count)
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            out.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        return out
    }

    // MARK: - The frame

    func testACompressedBlobInflatesWithAPlainZlibReader() throws {
        let original = Data(
            String(repeating: "Marshal save data, deflates well. ", count: 64).utf8)
        let encoded = BlobCodec.encode(original)

        XCTAssertEqual(encoded.algorithm, .zlib)
        XCTAssertLessThan(encoded.bytes.count, original.count)
        XCTAssertEqual(try inflateWithAPlainZlibReader(encoded.bytes), original)
    }

    func testACompressedManifestInflatesWithAPlainZlibReader() throws {
        let manifest = try BackupFixtures.data("manifest-v1.json")
        let framed = try BlobCodec.encodeZlib(manifest)

        XCTAssertEqual(try inflateWithAPlainZlibReader(framed), manifest)
    }

    /// A stream a real zlib wrote, so the reader is proven against
    /// something this repo did not produce.
    func testAStreamFromARealZlibReadsBack() throws {
        let framed = try BackupFixtures.data("blob-plain.zlib")
        let plain = try BackupFixtures.data("blob-plain.txt")

        XCTAssertEqual(try BlobCodec.decode(framed, algorithm: .zlib), plain)
    }

    // MARK: - The smaller of the two, per 5.6

    func testAnIncompressibleBlobIsStoredAsItIs() throws {
        let original = incompressibleBytes(count: 8_192)
        let encoded = BlobCodec.encode(original)

        XCTAssertEqual(encoded.algorithm, .stored)
        XCTAssertEqual(encoded.bytes, original)
        XCTAssertEqual(try BlobCodec.decode(encoded.bytes, algorithm: .stored), original)
    }

    func testAnEmptyBlobIsStored() throws {
        let encoded = BlobCodec.encode(Data())

        XCTAssertEqual(encoded.algorithm, .stored)
        XCTAssertTrue(encoded.bytes.isEmpty)
    }

    /// A zlib stream of no bytes is still a zlib stream a desktop
    /// tool must read. `ZlibInflate` reports no output as a failure,
    /// so the check is against the bytes a real zlib writes for an
    /// empty input.
    func testAnEmptyInputStillFramesAsZlib() throws {
        let framed = try BlobCodec.encodeZlib(Data())

        XCTAssertEqual(framed, Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]))
        XCTAssertEqual(try BlobCodec.decode(framed, algorithm: .zlib), Data())
    }

    func testEveryBlobRoundTripsThroughItsRecordedAlgorithm() throws {
        let cases: [Data] = [
            Data(),
            Data("a".utf8),
            Data(String(repeating: "z", count: 100_000).utf8),
            incompressibleBytes(count: 4_096),
            try BackupFixtures.data("manifest-v1.json"),
        ]
        for original in cases {
            let encoded = BlobCodec.encode(original)
            XCTAssertEqual(
                try BlobCodec.decode(encoded.bytes, algorithm: encoded.algorithm),
                original,
                "\(original.count) bytes as \(encoded.algorithm.rawValue)")
        }
    }

    /// A blob larger than one output buffer of the streaming reader.
    func testALargeBlobRoundTrips() throws {
        let original = Data(String(repeating: "save slot ", count: 40_000).utf8)
        let encoded = BlobCodec.encode(original)

        XCTAssertEqual(encoded.algorithm, .zlib)
        XCTAssertGreaterThan(original.count, 64 * 1_024)
        XCTAssertEqual(try BlobCodec.decode(encoded.bytes, algorithm: .zlib), original)
    }

    // MARK: - Rejections

    func testABrokenChecksumIsRejected() throws {
        let original = Data(String(repeating: "save data ", count: 64).utf8)
        var framed = try BlobCodec.encodeZlib(original)
        framed[framed.count - 1] ^= 0xFF

        XCTAssertThrowsError(try BlobCodec.decode(framed, algorithm: .zlib)) { error in
            XCTAssertEqual(error as? BlobCodec.Failure, .checksumMismatch)
        }
    }

    func testBytesThatAreNoZlibStreamAreRejected() {
        for bytes in [Data(), Data([0x00]), Data([0x00, 0x00, 0x01, 0x02, 0x03, 0x04])] {
            XCTAssertThrowsError(try BlobCodec.decode(bytes, algorithm: .zlib)) { error in
                XCTAssertEqual(error as? BlobCodec.Failure, .corruptZlibStream)
            }
        }
    }

    func testTheAdler32MatchesTheKnownValueOfWikipedia() {
        // "Wikipedia" is the worked example of RFC 1950's Adler-32.
        XCTAssertEqual(BlobCodec.adler32(Data("Wikipedia".utf8)), 0x11E6_0398)
        XCTAssertEqual(BlobCodec.adler32(Data()), 1)
    }

    /// The batched loop and the plain loop agree past one block of
    /// 5552 bytes.
    func testTheAdler32AgreesWithAPlainLoopOverALongInput() {
        let bytes = incompressibleBytes(count: 20_000)
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in bytes {
            low = (low + UInt32(byte)) % 65_521
            high = (high + low) % 65_521
        }
        XCTAssertEqual(BlobCodec.adler32(bytes), (high << 16) | low)
    }
}

import Foundation
import XCTest

@testable import GameProbe

final class ContentHashTests: XCTestCase {

    /// The digest of the empty input, from RFC 6234.
    private let emptyDigest =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// The digest of "abc", from RFC 6234.
    private let abcDigest =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("empo-content-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testTheFunctionNameIsWhatFormatJSONRecords() {
        XCTAssertEqual(ContentHash.functionName, "sha-256")
        XCTAssertEqual(FormatDescriptor().hashFunction, ContentHash.functionName)
    }

    func testHexOfDataMatchesTheKnownDigests() {
        XCTAssertEqual(ContentHash.hex(of: Data()), emptyDigest)
        XCTAssertEqual(ContentHash.hex(ofUTF8: "abc"), abcDigest)
    }

    func testHexOfFileMatchesHexOfData() throws {
        let file = scratch.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try ContentHash.hexOfFile(at: file), abcDigest)
    }

    func testHexOfAnEmptyFileMatchesTheEmptyDigest() throws {
        let file = scratch.appendingPathComponent("empty.bin")
        try Data().write(to: file)
        XCTAssertEqual(try ContentHash.hexOfFile(at: file), emptyDigest)
    }

    /// The file is larger than one read, so the loop runs more than
    /// once and the streaming path is the one under test.
    func testHexOfAFileLargerThanOneChunk() throws {
        var bytes = Data()
        bytes.reserveCapacity(ContentHash.chunkSize * 2 + 17)
        var value: UInt8 = 0
        for _ in 0..<(ContentHash.chunkSize * 2 + 17) {
            bytes.append(value)
            value = value &+ 31
        }
        let file = scratch.appendingPathComponent("large.bin")
        try bytes.write(to: file)

        XCTAssertEqual(try ContentHash.hexOfFile(at: file), ContentHash.hex(of: bytes))
    }

    func testAMissingFileReportsItsPath() {
        let file = scratch.appendingPathComponent("absent.bin")
        XCTAssertThrowsError(try ContentHash.hexOfFile(at: file)) { error in
            XCTAssertEqual(
                error as? ContentHash.Failure, .cannotReadFile(path: file.path))
        }
    }
}

import Foundation
import XCTest

@testable import GameProbe

#if canImport(Darwin)
import Darwin
#endif

/// The ZIP reader and writer against a full disk and hostile bytes.
final class PackageZipTests: XCTestCase {

    private var root = URL(fileURLWithPath: "/")
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("zip-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    // MARK: - A full disk

    /// Runs `body` while the process may grow no file past `bytes`.
    /// A write past the limit then fails with EFBIG, as on a full disk.
    private func withFileSizeLimit(_ bytes: Int, _ body: () throws -> Void) throws {
        #if canImport(Darwin)
        var old = rlimit()
        getrlimit(RLIMIT_FSIZE, &old)
        let oldHandler = signal(SIGXFSZ, SIG_IGN)
        var limited = old
        limited.rlim_cur = rlim_t(bytes)
        setrlimit(RLIMIT_FSIZE, &limited)
        defer {
            setrlimit(RLIMIT_FSIZE, &old)
            signal(SIGXFSZ, oldHandler)
        }
        try body()
        #else
        try skipOrFail("this host sets no file size limit from a test")
        #endif
    }

    func testAFullDiskFailsTheWriteInsteadOfCrashing() throws {
        let url = root.appendingPathComponent("full.zip")
        let writer = try ZipWriter(creating: url)
        try withFileSizeLimit(16 * 1_024) {
            XCTAssertThrowsError(
                try writer.add(data: randomBytes(256 * 1_024), at: "big.png")
            ) {
                XCTAssertEqual($0 as? ZipFailure, .writeFailed("full.zip"))
            }
        }
        writer.cancel()
    }

    func testAFullDiskFailsTheExtractInsteadOfCrashing() throws {
        let url = root.appendingPathComponent("ok.zip")
        let writer = try ZipWriter(creating: url)
        try writer.add(data: randomBytes(256 * 1_024), at: "big.png")
        try writer.add(data: randomBytes(256 * 1_024), at: "big.bin")
        try writer.finish()

        let reader = try ZipReader(reading: url)
        defer { reader.close() }
        try withFileSizeLimit(16 * 1_024) {
            for entry in reader.entries {
                let out = root.appendingPathComponent("out-" + entry.path)
                XCTAssertThrowsError(try reader.extract(entry, to: out)) {
                    XCTAssertEqual($0 as? ZipReader.Failure, .cannotWrite(entry.path))
                }
            }
        }
    }
}

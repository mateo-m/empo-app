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
    private func withFileSizeLimit(_ bytes: Int, _ body: () async throws -> Void) async throws {
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
        try await body()
        #else
        try skipOrFail("this host sets no file size limit from a test")
        #endif
    }

    func testAFullDiskFailsTheWriteInsteadOfCrashing() async throws {
        let url = root.appendingPathComponent("full.zip")
        let writer = try ZipWriter(creating: url)
        try await withFileSizeLimit(16 * 1_024) {
            XCTAssertThrowsError(
                try writer.add(data: randomBytes(256 * 1_024), at: "big.png")
            ) {
                XCTAssertEqual($0 as? ZipFailure, .writeFailed("full.zip"))
            }
        }
        writer.cancel()
    }

    func testAFullDiskFailsTheExtractInsteadOfCrashing() async throws {
        let url = root.appendingPathComponent("ok.zip")
        let writer = try ZipWriter(creating: url)
        try writer.add(data: randomBytes(256 * 1_024), at: "big.png")
        try writer.add(data: randomBytes(256 * 1_024), at: "big.bin")
        try writer.finish()

        let reader = try ZipReader(reading: url)
        defer { reader.close() }
        try await withFileSizeLimit(16 * 1_024) {
            for entry in reader.entries {
                let out = root.appendingPathComponent("out-" + entry.path)
                XCTAssertThrowsError(try reader.extract(entry, to: out)) {
                    XCTAssertEqual($0 as? ZipReader.Failure, .cannotWrite(entry.path))
                }
            }
        }
    }

    // MARK: - Hostile bytes

    /// A ZIP the real writer made, with one field of the central
    /// record of `path` then overwritten.
    private func zip(
        _ files: [(String, Data)], patching path: String, at field: Int, with bytes: [UInt8]
    ) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".zip")
        let writer = try ZipWriter(creating: url)
        for (name, data) in files { try writer.add(data: data, at: name) }
        try writer.finish()

        var raw = try Data(contentsOf: url)
        let name = Data(path.utf8)
        var index = 0
        while index + 46 <= raw.count {
            if raw.u32(index) == 0x0201_4B50,
                raw.subdata(in: (index + 46)..<(index + 46 + name.count)) == name
            {
                raw.replaceSubrange((index + field)..<(index + field + bytes.count), with: bytes)
                try raw.write(to: url)
                return url
            }
            index += 1
        }
        throw ZipReader.Failure.notAZip
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    func testAZip64CountPastWhatTheDirectoryHoldsIsRefused() throws {
        for count in [UInt64.max, UInt64(Int.max), 1_000_000] {
            let url = root.appendingPathComponent("count.zip")
            try zip64EndRecords(count: count).write(to: url)
            XCTAssertThrowsError(try ZipReader(reading: url)) {
                XCTAssertEqual($0 as? ZipReader.Failure, .truncated)
            }
        }
    }

    /// An empty central directory with ZIP64 end records that claim
    /// `count` entries.
    private func zip64EndRecords(count: UInt64) -> Data {
        var file = Data()
        file.append(le32: 0x0606_4B50)
        file.append(le64: 44)
        file.append(le16: 45)
        file.append(le16: 45)
        file.append(le32: 0)
        file.append(le32: 0)
        file.append(le64: Int64(bitPattern: count))
        file.append(le64: Int64(bitPattern: count))
        file.append(le64: 0)
        file.append(le64: 0)
        file.append(le32: 0x0706_4B50)
        file.append(le32: 0)
        file.append(le64: 0)
        file.append(le32: 1)
        file.append(le32: 0x0605_4B50)
        file.append(le16: 0)
        file.append(le16: 0)
        file.append(le16: 0xFFFF)
        file.append(le16: 0xFFFF)
        file.append(le32: 0xFFFF_FFFF)
        file.append(le32: 0xFFFF_FFFF)
        file.append(le16: 0)
        return file
    }

    /// The directory says 100 bytes, and the body inflates to 8 MB.
    func testAnEntryThatInflatesPastItsDeclaredSizeStopsThere() throws {
        let url = try zip(
            [("bomb.bin", Data(count: 8 * 1_024 * 1_024))],
            patching: "bomb.bin", at: 24, with: le32(100))
        let reader = try ZipReader(reading: url)
        defer { reader.close() }
        let entry = try XCTUnwrap(reader.entry(at: "bomb.bin"))
        XCTAssertTrue(entry.isDeflated)

        let out = root.appendingPathComponent("bomb.out")
        XCTAssertThrowsError(try reader.extract(entry, to: out)) {
            XCTAssertEqual($0 as? ZipReader.Failure, .wrongSize("bomb.bin"))
        }
        let written = try fm.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(written, 100)
        XCTAssertThrowsError(try reader.data(of: entry)) {
            XCTAssertEqual($0 as? ZipReader.Failure, .wrongSize("bomb.bin"))
        }
    }

    func testAStoredEntryLongerThanItsDeclaredSizeStopsThere() throws {
        let url = try zip(
            [("big.png", Data(repeating: 9, count: 4_096))],
            patching: "big.png", at: 24, with: le32(100))
        let reader = try ZipReader(reading: url)
        defer { reader.close() }
        let entry = try XCTUnwrap(reader.entry(at: "big.png"))
        XCTAssertFalse(entry.isDeflated)

        let out = root.appendingPathComponent("big.out")
        XCTAssertThrowsError(try reader.extract(entry, to: out)) {
            XCTAssertEqual($0 as? ZipReader.Failure, .wrongSize("big.png"))
        }
        let written = try fm.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(written, 100)
    }

    func testAnEntryShorterThanItsDeclaredSizeIsRefused() throws {
        let url = try zip(
            [("save.bin", Data(repeating: 4, count: 1_000))],
            patching: "save.bin", at: 24, with: le32(2_000))
        let reader = try ZipReader(reading: url)
        defer { reader.close() }
        let entry = try XCTUnwrap(reader.entry(at: "save.bin"))
        XCTAssertThrowsError(try reader.data(of: entry)) {
            XCTAssertEqual($0 as? ZipReader.Failure, .wrongSize("save.bin"))
        }
    }

    /// Method 12 is bzip2, which this reader does not inflate.
    func testAnUnknownCompressionMethodIsRefused() throws {
        let url = try zip(
            [("save.bin", Data(repeating: 4, count: 1_000))],
            patching: "save.bin", at: 10, with: [12, 0])
        XCTAssertThrowsError(try ZipReader(reading: url)) {
            XCTAssertEqual($0 as? ZipReader.Failure, .unsupportedMethod("save.bin"))
        }
    }

    func testAManifestPastTheSizeLimitIsRefusedUnread() throws {
        let manifest = try PackageManifest(exportedAt: Date(), sourceDevice: "iPad").jsonData()
        let url = try zip(
            [(PackageLayout.manifestPath, manifest)],
            patching: PackageLayout.manifestPath, at: 24,
            with: le32(UInt32(PackageValidation.manifestSizeLimit + 1)))
        XCTAssertThrowsError(try PackageSource(zip: url, packageId: "p1")) {
            XCTAssertEqual($0 as? PackageRejection, .unreadableManifest)
        }
    }

    // MARK: - What the import says

    /// A one-file package and the path a restore asks for its blob.
    private func package(_ bytes: Data) throws -> (url: URL, zipPath: String, blobPath: String) {
        var manifest = SnapshotManifest(mode: .slim, containerFolderName: "Quest")
        manifest.entries = [
            SnapshotManifest.Entry(
                root: .container, path: "Game/cover.png", size: Int64(bytes.count),
                modifiedAt: Date(), hash: ContentHash.hex(of: bytes), compression: .stored)
        ]
        let package = PackageManifest(
            exportedAt: Date(), sourceDevice: "iPad",
            streams: [PackageStream(key: manifest.gameKey, manifest: manifest)])
        let zipPath = try XCTUnwrap(package.files.first).zipPath

        let url = root.appendingPathComponent(UUID().uuidString + ".zip")
        let writer = try ZipWriter(creating: url)
        try writer.add(data: bytes, at: zipPath)
        try writer.add(data: package.jsonData(), at: PackageLayout.manifestPath)
        try writer.finish()
        let blobPath = BackupNamespacePaths(root: "", namespaceId: "p1").blobPath(
            hash: ContentHash.hex(of: bytes), fanOutWidth: FormatDescriptor.version1FanOutWidth)
        return (url, zipPath, blobPath)
    }

    func testADamagedFileSaysItDoesNotMatchTheHash() async throws {
        let bytes = randomBytes(4_096)
        let package = try package(bytes)
        var raw = try Data(contentsOf: package.url)
        let body = try XCTUnwrap(raw.range(of: bytes))
        raw[body.lowerBound + 100] ^= 0xFF
        try raw.write(to: package.url)

        let source = try PackageSource(zip: package.url, packageId: "p1")
        do {
            try await source.get(
                path: package.blobPath, localFile: root.appendingPathComponent("blob"))
            XCTFail("a damaged file staged")
        } catch {
            XCTAssertEqual(
                error, .rejected(message: PackageRejection.wrongHash(package.zipPath).line))
        }
        await source.close()
    }

    func testAFullDiskDuringTheImportSaysTheDeviceIsFull() async throws {
        let package = try package(randomBytes(256 * 1_024))
        let source = try PackageSource(zip: package.url, packageId: "p1")
        try await withFileSizeLimit(16 * 1_024) {
            do {
                try await source.get(
                    path: package.blobPath, localFile: root.appendingPathComponent("blob"))
                XCTFail("a full disk staged the file")
            } catch {
                XCTAssertEqual(error as? BackupProviderError, .outOfSpace)
            }
        }
        await source.close()
    }

    func testAPackageWithAnUnknownCompressionSaysSo() throws {
        let url = try zip(
            [("Documents/Games/Quest/Game/Save01.rvdata2", Data(repeating: 4, count: 1_000))],
            patching: "Documents/Games/Quest/Game/Save01.rvdata2", at: 10, with: [12, 0])
        XCTAssertThrowsError(try PackageSource(zip: url, packageId: "p1")) {
            XCTAssertEqual(
                $0 as? PackageRejection,
                .unsupportedCompression("Documents/Games/Quest/Game/Save01.rvdata2"))
        }
    }
}

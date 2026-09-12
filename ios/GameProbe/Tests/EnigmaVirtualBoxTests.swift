import XCTest

@testable import GameProbe

final class EnigmaVirtualBoxTests: XCTestCase {

    /// The PE headers, the whole file table, and the first two file
    /// bodies of a packed Pokemon Essentials game. The section
    /// header was patched so the table sits right after the headers.
    private var fixtureURL: URL {
        Bundle.module.url(forResource: "packed-table", withExtension: "exe", subdirectory: "Fixtures/enigma")!
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/enigma"))
        return try Data(contentsOf: url)
    }

    func testReadsTheFileTable() throws {
        let package = try XCTUnwrap(EnigmaVirtualBox.open(fixtureURL))
        XCTAssertEqual(package.entries.count, 3738)
        XCTAssertEqual(package.entries[0].path, "Data/abilities.dat")
        XCTAssertEqual(package.entries[0].originalSize, 32254)
        XCTAssertEqual(package.entries[1].path, "Data/Actors.rxdata")
        let paths = Set(package.entries.map(\.path))
        XCTAssertTrue(paths.contains("Game.ini"))
        XCTAssertTrue(paths.contains("mkxp.json"))
        XCTAssertTrue(paths.contains("Data/Scripts.rxdata"))
        XCTAssertTrue(paths.contains("Plugins/Pokemon Survivor/999_Entry/001_Entry.rb"))
    }

    func testUnpacksStoredFiles() throws {
        let package = try XCTUnwrap(EnigmaVirtualBox.open(fixtureURL))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        for entry in package.entries.prefix(2) {
            try package.unpack(entry, to: dir.appendingPathComponent(entry.path))
        }
        XCTAssertEqual(
            try Data(contentsOf: dir.appendingPathComponent("Data/abilities.dat")),
            try fixture("abilities.dat"))
        XCTAssertEqual(
            try Data(contentsOf: dir.appendingPathComponent("Data/Actors.rxdata")),
            try fixture("Actors.rxdata"))
    }

    func testRejectsAnExeWithoutAContainer() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = Data(repeating: 0, count: 0x200)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        bytes[0x3C] = 0x80
        bytes[0x80] = 0x50
        bytes[0x81] = 0x45
        try bytes.write(to: url)
        XCTAssertNil(EnigmaVirtualBox.open(url))
    }

    func testAPLibDecompressesTheReferenceVector() throws {
        let packed = Data([
            0x54, 0x00, 0x68, 0x65, 0x20, 0x71, 0x75, 0x69, 0x63, 0x6B, 0xEC, 0x62, 0x0E, 0x72,
            0x6F, 0x77, 0x6E, 0xCE, 0x66, 0xAE, 0x78, 0x80, 0x6A, 0x75, 0x6D, 0x70, 0x73, 0xED,
            0xE4, 0x76, 0x65, 0x75, 0x72, 0x60, 0x74, 0x3F, 0x6C, 0x61, 0x7A, 0x79, 0xEA, 0x64,
            0xFE, 0x67, 0xC0, 0x00,
        ])
        XCTAssertEqual(
            String(decoding: try APLib.decompress(packed), as: UTF8.self),
            "The quick brown fox jumps over the lazy dog")
    }

    /// Full round trip against a real packed exe. Set
    /// `EMPO_ENIGMA_SAMPLE_EXE` to the exe and
    /// `EMPO_ENIGMA_SAMPLE_DIR` to a reference unpack of it.
    func testMatchesReferenceUnpack() throws {
        let env = ProcessInfo.processInfo.environment
        guard let exePath = env["EMPO_ENIGMA_SAMPLE_EXE"], let refPath = env["EMPO_ENIGMA_SAMPLE_DIR"]
        else {
            throw XCTSkip("no sample exe configured")
        }
        let package = try XCTUnwrap(EnigmaVirtualBox.open(URL(fileURLWithPath: exePath)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        for entry in package.entries {
            let out = dir.appendingPathComponent(entry.path)
            try package.unpack(entry, to: out)
            let reference = URL(fileURLWithPath: refPath).appendingPathComponent(entry.path)
            XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: reference), entry.path)
        }
    }
}

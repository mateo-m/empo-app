import XCTest

@testable import GameProbe

final class SettingsFileTests: XCTestCase {

    private var folder: URL!
    private var url: URL { folder.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func read() throws -> [String: String] {
        try SettingsFile.value(at: url, empty: { [:] }) {
            try JSONDecoder().decode([String: String].self, from: $0)
        }
    }

    private func damagedCopies() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("settings.json.damaged-") }
    }

    func testADamagedReadKeepsAFileThatAnotherReaderSavedMeanwhile() throws {
        try Data("{".utf8).write(to: url)
        let saved = Data(#"{"a":"saved"}"#.utf8)

        let value = try SettingsFile.value(at: url, empty: { [String: String]() }) { data in
            try saved.write(to: url, options: .atomic)
            return try JSONDecoder().decode([String: String].self, from: data)
        }

        XCTAssertEqual(value, [:])
        XCTAssertEqual(try Data(contentsOf: url), saved)
        XCTAssertEqual(try read(), ["a": "saved"])
    }

    func testTheSameDamagedBytesWrittenTwiceKeepOneCopy() throws {
        let damaged = Data("{".utf8)
        try damaged.write(to: url)
        XCTAssertEqual(try read(), [:])
        try damaged.write(to: url)
        XCTAssertEqual(try read(), [:])

        let copies = try damagedCopies()
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent(try XCTUnwrap(copies.first))),
            damaged)
    }
}

import XCTest

@testable import Empo

final class GameReportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = DataDirectory.documentsRootURL
            .appendingPathComponent("GameReportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testReportHoldsEveryByteOfALongLog() throws {
        // Longer than one part of the copy, and not valid UTF-8.
        let log = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let logURL = folder.appendingPathComponent("2026-10-04T20-00-00Z.log")
        try log.write(to: logURL)

        let url = try GameReport(gameTitle: "Game", logURL: logURL).write(header: "header")

        XCTAssertEqual(try Data(contentsOf: url), Data("header\n".utf8) + log)
    }

    func testReportOfAMissingLogSaysSo() throws {
        let logURL = folder.appendingPathComponent("2026-10-04T20-00-01Z.log")

        let url = try GameReport(gameTitle: "Game", logURL: logURL).write(header: "header")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "header\nThe session log is missing.\n")
    }
}

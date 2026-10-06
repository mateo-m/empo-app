import XCTest

@testable import Empo

@MainActor
final class SessionLoggerTests: XCTestCase {
    private var logsDir: URL!

    override func setUpWithError() throws {
        logsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: logsDir)
    }

    func testPruneDeletesOnlyTheOldestSessionLogs() throws {
        let sessionLogs = [
            "2026-09-15T04-13-22Z.log",
            "2026-09-15T23-59-59Z.log",
            "2026-09-16T00-00-00Z.log",
            "2026-09-16T21-04-06Z.log",
        ]
        let diagnostics = ["controls.json.log", "engine-config.log", "session-history.log"]
        // The diagnostics are the oldest files, and the session logs are
        // written newest first, so an order by creation date picks the
        // wrong files.
        for name in diagnostics + sessionLogs.reversed() {
            try "x".write(to: logsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        SessionLogger.pruneSessionLogs(in: logsDir, keeping: 2)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: logsDir.path).sorted()
        XCTAssertEqual(remaining, (diagnostics + sessionLogs.suffix(2)).sorted())
    }

    func testPruneKeepsEverySessionLogUnderTheLimit() throws {
        for name in ["controls.json.log", "2026-09-16T21-04-06Z.log"] {
            try "x".write(to: logsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        SessionLogger.pruneSessionLogs(in: logsDir, keeping: 1)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: logsDir.path).sorted()
        XCTAssertEqual(remaining, ["2026-09-16T21-04-06Z.log", "controls.json.log"])
    }

    func testSessionLogNameRoundTrips() {
        let name = SessionLogger.sessionLogName(for: Date(timeIntervalSince1970: 1_789_592_646))
        XCTAssertEqual(name, "2026-09-16T21-04-06Z.log")
        XCTAssertTrue(SessionLogger.isSessionLogName(name))
        for other in [
            "controls.json.log", "engine-config.log", "session-history.log", "2026-09-16T21-04-06Z.txt",
        ] {
            XCTAssertFalse(SessionLogger.isSessionLogName(other), other)
        }
    }
}

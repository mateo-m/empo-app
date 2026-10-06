import Foundation
import XCTest

@testable import GameProbe

/// `EmpoState/backup.json`, per SPEC 3.8.
final class GameBackupIntentTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameBackupIntentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func object(_ data: Data) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    // MARK: - The round trip

    func testTheIntentRoundTrips() throws {
        var intent = GameBackupIntent(
            mode: .slim,
            manualMarks: ["Game/Data/custom.sav"],
            declinedSuggestions: ["Game/patch.exe"])
        intent.manualMarks.append("Game/Save/slot2.rvdata2")

        let read = try GameBackupIntent.decode(json: intent.jsonData())

        XCTAssertEqual(read, intent)
        XCTAssertEqual(read.mode, .slim)
        XCTAssertEqual(read.version, GameBackupIntent.currentVersion)
        XCTAssertEqual(
            read.manualMarks, ["Game/Data/custom.sav", "Game/Save/slot2.rvdata2"])
        XCTAssertEqual(read.declinedSuggestions, ["Game/patch.exe"])
    }

    func testAnEmptyIntentHasNoModeYet() {
        // No mode means the game has not answered the threshold ask
        // of 3.5. Ticket 003 resolves that.
        XCTAssertNil(GameBackupIntent().mode)
        XCTAssertEqual(GameBackupIntent().manualMarks, [])
    }

    func testTheModeIsAScalar() throws {
        let intent = GameBackupIntent(mode: .full)

        XCTAssertEqual(try object(intent.jsonData())["mode"], .string("full"))
    }

    // MARK: - A future file

    func testAnUnknownVersionAndItsFieldsSurviveAReadAndAWrite() throws {
        // The version field is there so the mode scalar can become a
        // per-target map later, per 3.8. A build that predates that
        // change must give the file back whole.
        let future = """
            {
              "version": 99,
              "mode": {"target-a": "slim", "target-b": "full"},
              "manualMarks": ["Game/Save/slot1.rvdata2"],
              "declinedSuggestions": [],
              "retentionOverride": {"preset": "deep"},
              "pinnedSnapshots": ["20260501T010203Z-abc123"]
            }
            """.data(using: .utf8)!

        let intent = try GameBackupIntent.decode(json: future)
        let written = try object(intent.jsonData())

        XCTAssertEqual(intent.version, 99)
        XCTAssertNil(intent.mode)
        XCTAssertEqual(written, try object(future))
    }

    func testSettingTheModeOnAFutureFileKeepsTheOtherFields() throws {
        let future = """
            {"version": 99, "mode": {"target-a": "slim"}, "futureFlag": true}
            """.data(using: .utf8)!

        var intent = try GameBackupIntent.decode(json: future)
        intent.mode = .full
        let written = try object(intent.jsonData())

        XCTAssertEqual(written["mode"], .string("full"))
        XCTAssertEqual(written["futureFlag"], .bool(true))
        XCTAssertEqual(written["version"], .int(99))
    }

    func testAFileWithNoVersionReadsAsThisVersion() throws {
        let data = #"{"mode": "slim"}"#.data(using: .utf8)!

        let intent = try GameBackupIntent.decode(json: data)

        XCTAssertEqual(intent.version, GameBackupIntent.currentVersion)
        XCTAssertEqual(intent.mode, .slim)
    }

    func testAnUnknownModeLabelReadsAsNoMode() throws {
        let data = #"{"version": 1, "mode": "archival"}"#.data(using: .utf8)!

        XCTAssertNil(try GameBackupIntent.decode(json: data).mode)
    }

    // MARK: - The file

    func testSaveAndLoadThroughEmpoState() throws {
        let stateDirectory = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        let intent = GameBackupIntent(mode: .slim, manualMarks: ["Game/Save"])

        // The directory is not there yet, the way it is not there
        // before the first settings write.
        try intent.save(to: stateDirectory)

        XCTAssertEqual(GameBackupIntent.load(from: stateDirectory), intent)
        XCTAssertEqual(GameBackupIntent.fileName, "backup.json")
    }

    func testAMissingFileLoadsTheEmptyIntent() {
        XCTAssertEqual(GameBackupIntent.load(from: tempRoot), GameBackupIntent())
    }

    func testAnUnreadableFileLoadsTheEmptyIntent() throws {
        try "not json at all".write(
            to: tempRoot.appendingPathComponent(GameBackupIntent.fileName),
            atomically: true, encoding: .utf8)

        XCTAssertEqual(GameBackupIntent.load(from: tempRoot), GameBackupIntent())
    }
}

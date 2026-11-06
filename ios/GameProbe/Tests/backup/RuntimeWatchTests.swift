import Foundation
import XCTest

@testable import GameProbe

/// The runtime watch of SPEC 3.6 and the save-file editor of 3.7.
final class RuntimeWatchTests: XCTestCase {

    private let megabyte: Int64 = 1024 * 1024
    private let start = Date(timeIntervalSince1970: 1_777_593_600)

    private func file(_ path: String, megabytes: Int64) -> BackupSetResolver.WalkedFile {
        BackupSetResolver.WalkedFile(
            path: path, size: megabytes * megabyte, modifiedAt: start)
    }

    // MARK: - The size limit

    func testTheLimitIs50MB() {
        XCTAssertEqual(RuntimeWatch.askAboveBytes, 50 * megabyte)
    }

    func testASmallWriteJoinsOnItsOwn() {
        let result = RuntimeWatch.result(
            written: [file("Game/Game.rxdata", megabytes: 10)],
            mode: .slim,
            declined: [],
            alreadyInSet: [])

        XCTAssertEqual(result.joined, ["Game/Game.rxdata"])
        XCTAssertTrue(result.asks.isEmpty)
    }

    func testAWriteOverTheLimitAsksInsteadOfJoining() {
        let result = RuntimeWatch.result(
            written: [file("Game/patch.exe", megabytes: 60)],
            mode: .slim,
            declined: [],
            alreadyInSet: [])

        XCTAssertEqual(result.asks, ["Game/patch.exe"])
        XCTAssertTrue(result.joined.isEmpty)
    }

    func testAWriteExactlyAtTheLimitStillJoins() {
        let outcome = RuntimeWatch.outcome(
            path: "Game/Game.rxdata",
            sizeBytes: RuntimeWatch.askAboveBytes,
            mode: .slim,
            declined: [],
            alreadyInSet: [])

        XCTAssertEqual(outcome, .join)
    }

    // MARK: - Declined files never ask twice

    func testADeclinedFileBecomesASuggestionAndDoesNotAskAgain() {
        let result = RuntimeWatch.result(
            written: [file("Game/patch.exe", megabytes: 60)],
            mode: .slim,
            declined: ["Game/patch.exe"],
            alreadyInSet: [])

        XCTAssertEqual(result.suggestions, ["Game/patch.exe"])
        XCTAssertTrue(result.asks.isEmpty)
        XCTAssertTrue(result.joined.isEmpty)
    }

    func testDecliningWritesThePathIntoTheIntent() {
        let intent = RuntimeWatch.declining("Game/patch.exe", in: GameBackupIntent())

        XCTAssertEqual(intent.declinedSuggestions, ["Game/patch.exe"])
    }

    func testDecliningTheSamePathTwiceWritesOneEntry() {
        var intent = RuntimeWatch.declining("Game/patch.exe", in: GameBackupIntent())
        intent = RuntimeWatch.declining("Game/patch.exe", in: intent)

        XCTAssertEqual(intent.declinedSuggestions, ["Game/patch.exe"])
    }

    // MARK: - Full mode changes nothing

    func testFullModeIgnoresEveryWrite() {
        let result = RuntimeWatch.result(
            written: [
                file("Game/Game.rxdata", megabytes: 10),
                file("Game/patch.exe", megabytes: 60),
            ],
            mode: .full,
            declined: [],
            alreadyInSet: [])

        XCTAssertTrue(result.isEmpty)
    }

    func testAFileTheSetAlreadyHoldsNeedsNoSecondSource() {
        let result = RuntimeWatch.result(
            written: [file("Game/Game.rxdata", megabytes: 10)],
            mode: .slim,
            declined: [],
            alreadyInSet: ["Game/Game.rxdata"])

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - The two readings

    func testANewFileCountsAsWritten() {
        let written = RuntimeWatch.writtenPaths(
            before: [:], after: ["Game/Game.rxdata": FileStamp(size: 10, modifiedAt: start)])

        XCTAssertEqual(written, ["Game/Game.rxdata"])
    }

    func testAChangedSizeOrTimeCountsAsWritten() {
        let before = ["a": FileStamp(size: 10, modifiedAt: start)]
        let biggerSize = ["a": FileStamp(size: 20, modifiedAt: start)]
        let laterTime = ["a": FileStamp(size: 10, modifiedAt: start.addingTimeInterval(60))]

        XCTAssertEqual(RuntimeWatch.writtenPaths(before: before, after: biggerSize), ["a"])
        XCTAssertEqual(RuntimeWatch.writtenPaths(before: before, after: laterTime), ["a"])
    }

    func testAnUntouchedFileIsNotWritten() {
        let stamps = ["a": FileStamp(size: 10, modifiedAt: start)]

        XCTAssertTrue(RuntimeWatch.writtenPaths(before: stamps, after: stamps).isEmpty)
    }

    func testAFileThatWentAwayIsNotWritten() {
        let before = ["a": FileStamp(size: 10, modifiedAt: start)]

        XCTAssertTrue(RuntimeWatch.writtenPaths(before: before, after: [:]).isEmpty)
    }

    func testAFileWrittenDuringTheFirstReadingStillCounts() {
        // The first reading walks thousands of files, so a save the
        // game writes mid-walk can enter it already written. The
        // session start closes that race.
        let stamps = ["a": FileStamp(size: 10, modifiedAt: start.addingTimeInterval(2))]

        XCTAssertEqual(
            RuntimeWatch.writtenPaths(before: stamps, after: stamps, since: start), ["a"])
    }

    func testAFileOlderThanTheSessionStaysOut() {
        let stamps = ["a": FileStamp(size: 10, modifiedAt: start.addingTimeInterval(-60))]

        XCTAssertTrue(
            RuntimeWatch.writtenPaths(before: stamps, after: stamps, since: start).isEmpty)
    }

    // MARK: - The save-file editor, per 3.7

    private var editorModel: SaveFileEditorModel {
        let set = BackupSetResolver.resolve(
            GameBackupSetRequest(
                containerURL: BackupFixtures.url("container"),
                mode: .slim,
                manualMarks: ["Game/Data"]))
        return SaveFileEditorModel.from(set, manualMarks: ["Game/Data"])
    }

    func testTheEditorListsEveryDetectedSaveWithItsLabel() {
        let model = editorModel

        XCTAssertEqual(
            model.entries.map(\.path),
            [
                "Game/Data/Scripts.rxdata",
                "Game/Game.rxdata",
                "Game/Save Data/slot1.bin",
                "Game/autosave.sav",
                "Game/save1.dat",
            ])
        XCTAssertEqual(
            model.entries.first { $0.path == "Game/Data/Scripts.rxdata" }?.source, .manualMark)
        XCTAssertEqual(
            model.entries.first { $0.path == "Game/Game.rxdata" }?.source, .classifier)
    }

    func testTheEditorLeavesTheSettingsFilesOut() {
        XCTAssertFalse(editorModel.entries.map(\.path).contains("EmpoState/backup.json"))
    }

    func testAddingAPathMarksIt() {
        var model = editorModel
        model.add(path: "Game/patch.exe", sizeBytes: 512)

        XCTAssertTrue(model.manualMarks.contains("Game/patch.exe"))
        XCTAssertEqual(
            model.entries.first { $0.path == "Game/patch.exe" }?.source, .manualMark)
    }

    func testAddingAClassifierMatchTurnsItIntoAMark() {
        var model = editorModel
        model.add(path: "Game/Game.rxdata")

        XCTAssertEqual(
            model.entries.first { $0.path == "Game/Game.rxdata" }?.source, .manualMark)
        XCTAssertEqual(model.entries.filter { $0.path == "Game/Game.rxdata" }.count, 1)
    }

    func testOnlyAMarkComesOutAgain() {
        var model = editorModel

        XCTAssertTrue(model.remove(path: "Game/Data"))
        XCTAssertFalse(model.remove(path: "Game/Game.rxdata"))
        XCTAssertTrue(model.entries.contains { $0.path == "Game/Game.rxdata" })
    }

    func testOnlyAMarkIsRemovable() {
        for entry in editorModel.entries {
            XCTAssertEqual(entry.isRemovable, entry.source == .manualMark, entry.path)
        }
    }

    func testTheEditorWritesTheMarksBackIntoTheIntent() {
        var model = editorModel
        model.add(path: "Game/patch.exe")
        let intent = model.applied(to: GameBackupIntent(mode: .slim))

        XCTAssertEqual(intent.manualMarks, ["Game/Data", "Game/patch.exe"])
        XCTAssertEqual(intent.mode, .slim)
    }
}

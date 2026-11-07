import Foundation
import XCTest

@testable import GameProbe

/// The four triggers and their scan scope, per SPEC 7.3.
final class BackupTriggerPlanTests: XCTestCase {

    private let library = ["game-a", "game-b", "game-c"]

    private func dirty(_ keys: [String]) -> [DirtyMark] {
        keys.map {
            DirtyMark(targetId: "target-1", gameKey: $0, markedAt: Date(timeIntervalSince1970: 1))
        }
    }

    func testFourTriggersShipAndNoRefreshTaskIsAmongThem() {
        XCTAssertEqual(BackupTrigger.allCases.count, 4)
    }

    func testTheAppBackgroundPassReturnsDirtyGamesOnly() {
        let scope = BackupTriggerPlan.scope(of: .sessionEndOrBackground)
        XCTAssertEqual(scope, .dirtyGames)
        XCTAssertEqual(
            BackupTriggerPlan.games(
                in: scope, dirty: dirty(["game-c", "game-a"]), library: library, targetIds: ["target-1"]),
            ["game-a", "game-c"])
    }

    func testAMarkOnATargetThatDoesNotRunLeavesTheGameOut() {
        let paused = [DirtyMark(targetId: "paused", gameKey: "game-b", markedAt: Date())]
        XCTAssertEqual(
            BackupTriggerPlan.games(
                in: .dirtyGames, dirty: dirty(["game-a"]) + paused, library: library,
                targetIds: ["target-1"]),
            ["game-a"])
    }

    func testTheNightlyPassReturnsTheFullLibrary() {
        let scope = BackupTriggerPlan.scope(of: .nightly)
        XCTAssertEqual(scope, .wholeLibrary)
        XCTAssertEqual(
            BackupTriggerPlan.games(
                in: scope, dirty: dirty(["game-a"]), library: library, targetIds: ["target-1"]),
            library)
    }

    func testAGameWithAnUnfinishedRestoreSitsOutOfEveryScope() {
        XCTAssertEqual(
            BackupTriggerPlan.games(
                in: .wholeLibrary, dirty: [], library: library, targetIds: ["target-1"],
                restoring: "game-b"),
            ["game-a", "game-c"])
        XCTAssertEqual(
            BackupTriggerPlan.games(
                in: .dirtyGames, dirty: dirty(["game-b"]), library: library,
                targetIds: ["target-1"], restoring: "game-b"),
            [])
        XCTAssertEqual(
            BackupTriggerPlan.games(
                in: .oneGame(gameKey: "game-b"), dirty: [], library: library,
                targetIds: ["target-1"], restoring: "game-b"),
            [])
    }

    func testTheForegroundPassReturnsTheFullLibraryToo() {
        XCTAssertEqual(BackupTriggerPlan.scope(of: .foreground), .wholeLibrary)
    }

    func testTheForegroundPassWaitsThirtySeconds() {
        XCTAssertEqual(BackupTriggerPlan.foregroundDelay, 30)
    }

    func testThePerGamePressCoversThatGameAlone() {
        let press = ManualBackupPress.game(gameKey: "game-b", gameName: "Ib")
        let scope = BackupTriggerPlan.scope(of: .manual, press: press)
        XCTAssertEqual(scope, .oneGame(gameKey: "game-b"))
        XCTAssertEqual(
            BackupTriggerPlan.games(in: scope, dirty: [], library: library, targetIds: ["target-1"]),
            ["game-b"])
    }

    func testTheLibraryWidePressCoversEveryGame() {
        let scope = BackupTriggerPlan.scope(of: .manual, press: .library)
        XCTAssertEqual(scope, .wholeLibrary)
    }

    func testTheTaskTitleIsTheGameNameOrEmpoBackups() {
        XCTAssertEqual(
            BackupTriggerPlan.taskTitle(for: .game(gameKey: "game-b", gameName: "Ib")), "Ib")
        XCTAssertEqual(BackupTriggerPlan.taskTitle(for: .library), "Empo backups")
    }

    // MARK: - The mechanisms each trigger may use

    func testOnlyTheNightlyTaskRequiresExternalPower() {
        for trigger in BackupTrigger.allCases {
            XCTAssertEqual(
                BackupTriggerPlan.requiresExternalPower(trigger), trigger == .nightly,
                "\(trigger.rawValue)")
        }
    }

    // MARK: - The sweep

    func testTheNightlyTaskTakesADueSweep() {
        XCTAssertTrue(BackupTriggerPlan.runsSweep(.nightly, decision: .run))
        XCTAssertTrue(BackupTriggerPlan.runsSweep(.nightly, decision: .runOverdue))
        XCTAssertFalse(BackupTriggerPlan.runsSweep(.nightly, decision: .notDue))
        XCTAssertFalse(BackupTriggerPlan.runsSweep(.nightly, decision: .queued))
    }

    func testTheForegroundPassTakesAnOverdueSweepOnly() {
        XCTAssertFalse(BackupTriggerPlan.runsSweep(.foreground, decision: .run))
        XCTAssertTrue(BackupTriggerPlan.runsSweep(.foreground, decision: .runOverdue))
    }

    func testTheBackboneAndTheManualButtonNeverSweep() {
        for decision in [
            SweepSchedule.Decision.notDue, .queued, .run, .runOverdue,
        ] {
            XCTAssertFalse(
                BackupTriggerPlan.runsSweep(.sessionEndOrBackground, decision: decision))
            XCTAssertFalse(BackupTriggerPlan.runsSweep(.manual, decision: decision))
        }
    }
}

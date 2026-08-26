import Foundation
import XCTest

@testable import GameProbe

/// The size threshold and the first-backup ask of SPEC 3.5, the
/// retroactive rule of 3.10, and the mode change of 3.9.
final class BackupThresholdTests: XCTestCase {

    private let megabyte: Int64 = 1024 * 1024

    private func targets(_ values: [(String, Int64?)]) -> [BackupTargetThreshold] {
        values.map {
            BackupTargetThreshold(
                targetId: $0.0, displayName: $0.0.capitalized, overrideBytes: $0.1)
        }
    }

    // MARK: - The threshold

    func testTheDefaultIs750MB() {
        XCTAssertEqual(BackupThreshold.defaultBytes, 750 * megabyte)
    }

    func testATargetWithNoOverrideUsesTheDefault() {
        let target = BackupTargetThreshold(targetId: "icloud", displayName: "iCloud Drive")

        XCTAssertEqual(target.thresholdBytes, BackupThreshold.defaultBytes)
    }

    // MARK: - The ask, per 3.5

    func testAGameBelowTheThresholdEntersFullModeAndNeverMeetsTheAsk() {
        let resolution = BackupThreshold.resolveMode(
            intent: GameBackupIntent(),
            gameTreeBytes: BackupThreshold.defaultBytes - 1,
            targets: targets([("icloud", nil)]))

        XCTAssertEqual(resolution, .mode(.full))
    }

    func testAGameExactlyAtTheThresholdMeetsTheAsk() {
        let resolution = BackupThreshold.resolveMode(
            intent: GameBackupIntent(),
            gameTreeBytes: BackupThreshold.defaultBytes,
            targets: targets([("icloud", nil)]))

        XCTAssertEqual(
            resolution,
            .ask(
                BackupThresholdAsk(
                    gameTreeBytes: BackupThreshold.defaultBytes,
                    targetId: "icloud",
                    targetDisplayName: "Icloud",
                    thresholdBytes: BackupThreshold.defaultBytes)))
    }

    func testTheAskNamesTheTargetWithTheLowestThreshold() {
        let resolution = BackupThreshold.resolveMode(
            intent: GameBackupIntent(),
            gameTreeBytes: 400 * megabyte,
            targets: targets([("icloud", nil), ("dropbox", 300 * megabyte)]))

        guard case .ask(let ask) = resolution else {
            return XCTFail("the ask did not fire")
        }
        XCTAssertEqual(ask.targetId, "dropbox")
        XCTAssertEqual(ask.thresholdBytes, 300 * megabyte)
    }

    func testTheLowestThresholdDecidesEvenWhenAnotherTargetIsHappy() {
        // 400 MB is under iCloud's default and over Dropbox's
        // override, and the ask still fires. The answer then applies
        // to every target, because the mode is one scalar.
        let resolution = BackupThreshold.resolveMode(
            intent: GameBackupIntent(),
            gameTreeBytes: 400 * megabyte,
            targets: targets([("icloud", nil), ("dropbox", 300 * megabyte)]))

        XCTAssertNotEqual(resolution, .mode(.full))
    }

    func testATieGoesToTheFirstTarget() {
        let lowest = BackupThreshold.lowest(
            among: targets([("icloud", 300 * megabyte), ("dropbox", 300 * megabyte)]))

        XCTAssertEqual(lowest?.targetId, "icloud")
    }

    func testAGameThatAnsweredKeepsItsAnswer() {
        let intent = GameBackupIntent(mode: .slim)
        let resolution = BackupThreshold.resolveMode(
            intent: intent,
            gameTreeBytes: 10 * megabyte,
            targets: targets([("icloud", nil)]))

        XCTAssertEqual(resolution, .mode(.slim))
    }

    func testNoEnabledTargetMeansFullMode() {
        let resolution = BackupThreshold.resolveMode(
            intent: GameBackupIntent(), gameTreeBytes: 4000 * megabyte, targets: [])

        XCTAssertEqual(resolution, .mode(.full))
    }

    // MARK: - Retroactive classification, per 3.10

    func testALibraryImportedBeforeThisFeatureClassifiesAtTheFirstScan() {
        // No mode in `backup.json`, and no baseline manifest exists
        // anywhere in the design. The tree size alone decides.
        let small = BackupThreshold.resolveMode(
            intent: GameBackupIntent(),
            gameTreeBytes: 40 * megabyte,
            targets: targets([("icloud", nil)]))
        let large = BackupThreshold.resolveMode(
            intent: GameBackupIntent(),
            gameTreeBytes: 4000 * megabyte,
            targets: targets([("icloud", nil)]))

        XCTAssertEqual(small, .mode(.full))
        guard case .ask = large else {
            return XCTFail("the ask did not fire for the large game")
        }
    }

    // MARK: - Changing mode, per 3.9

    func testAModeChangeIsReversibleInBothDirections() {
        let slim = BackupModeChange.apply(.slim, to: GameBackupIntent(mode: .full))
        let backToFull = BackupModeChange.apply(.full, to: slim)

        XCTAssertEqual(slim.mode, .slim)
        XCTAssertEqual(backToFull.mode, .full)
    }

    func testAModeChangeKeepsTheMarks() {
        let intent = GameBackupIntent(
            mode: .full, manualMarks: ["Game/Data"], declinedSuggestions: ["Game/patch.exe"])
        let changed = BackupModeChange.apply(.slim, to: intent)

        XCTAssertEqual(changed.manualMarks, ["Game/Data"])
        XCTAssertEqual(changed.declinedSuggestions, ["Game/patch.exe"])
    }

    func testAModeChangeMakesTheGameDirty() {
        XCTAssertTrue(BackupModeChange.makesDirty(from: .full, to: .slim))
        XCTAssertTrue(BackupModeChange.makesDirty(from: nil, to: .full))
        XCTAssertFalse(BackupModeChange.makesDirty(from: .slim, to: .slim))
    }

    func testTheDirtyReasonIsStable() {
        XCTAssertEqual(BackupModeChange.dirtyReason, "mode-change")
    }
}

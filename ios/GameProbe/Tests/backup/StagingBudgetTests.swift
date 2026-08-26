import Foundation
import XCTest

@testable import GameProbe

/// The disk budget of SPEC 6.4.
final class StagingBudgetTests: XCTestCase {

    private let megabyte: Int64 = 1024 * 1024
    private let scanned = FileStamp(
        size: 2048, modifiedAt: Date(timeIntervalSince1970: 1_777_593_600))

    // MARK: - Which path a game takes

    func testTheCapIs512MBAndTheFloorIs200MB() {
        XCTAssertEqual(StagingBudget.stagingCapBytes, 512 * megabyte)
        XCTAssertEqual(StagingBudget.freeSpaceFloorBytes, 200 * megabyte)
    }

    func testSaveMembersUnderTheCapStage() {
        let route = StagingBudget.route(
            saveMembersBytes: 100 * megabyte,
            largestMemberBytes: 40 * megabyte,
            freeSpaceBytes: 4 * 1024 * megabyte)

        XCTAssertEqual(route, .staged)
    }

    func testSaveMembersOverTheCapGoInPlace() {
        let route = StagingBudget.route(
            saveMembersBytes: StagingBudget.stagingCapBytes + 1,
            largestMemberBytes: 40 * megabyte,
            freeSpaceBytes: 4 * 1024 * megabyte)

        XCTAssertEqual(route, .inPlace(.overStagingCap))
    }

    func testSaveMembersExactlyAtTheCapStillStage() {
        let route = StagingBudget.route(
            saveMembersBytes: StagingBudget.stagingCapBytes,
            largestMemberBytes: 8 * megabyte,
            freeSpaceBytes: 4 * 1024 * megabyte)

        XCTAssertEqual(route, .staged)
    }

    func testFreeSpaceBelowTheFloorGoesInPlace() {
        // The members fit under the cap, but the volume has less than
        // the members' size plus the 200 MB floor.
        let route = StagingBudget.route(
            saveMembersBytes: 100 * megabyte,
            largestMemberBytes: 40 * megabyte,
            freeSpaceBytes: 250 * megabyte)

        XCTAssertEqual(route, .inPlace(.belowFreeSpaceFloor))
    }

    func testFreeSpaceExactlyAtTheFloorStillStages() {
        let route = StagingBudget.route(
            saveMembersBytes: 100 * megabyte,
            largestMemberBytes: 40 * megabyte,
            freeSpaceBytes: 300 * megabyte)

        XCTAssertEqual(route, .staged)
    }

    func testNoRoomForOneBlobStopsTheGame() {
        // Rule 6: the in-place path needs room for one compressed
        // blob in the outbox. Under that, the run stops for the game.
        let route = StagingBudget.route(
            saveMembersBytes: 900 * megabyte,
            largestMemberBytes: 40 * megabyte,
            freeSpaceBytes: 8 * megabyte)

        XCTAssertEqual(route, .notEnoughSpace)
        XCTAssertEqual(
            StagingBudget.notEnoughSpaceLine, "not enough space on this device")
    }

    // MARK: - The re-check after a copy, rule 2

    func testAnUnchangedFileIsAccepted() {
        let outcome = StagingBudget.recheck(
            scanned: scanned, afterCopy: scanned, attempt: 1)

        XCTAssertEqual(outcome, .accepted)
    }

    func testAFileChangedOnceRestages() {
        let grew = FileStamp(size: 4096, modifiedAt: scanned.modifiedAt)

        XCTAssertEqual(
            StagingBudget.recheck(scanned: scanned, afterCopy: grew, attempt: 1),
            .restage)
    }

    func testAFileChangedTwiceIsSkippedAndMarkedPartial() {
        let touched = FileStamp(
            size: scanned.size, modifiedAt: scanned.modifiedAt.addingTimeInterval(1))

        XCTAssertEqual(
            StagingBudget.recheck(scanned: scanned, afterCopy: touched, attempt: 2),
            .skipAndMarkPartial)
    }

    func testASecondCopyThatMatchesIsStillAccepted() {
        XCTAssertEqual(
            StagingBudget.recheck(scanned: scanned, afterCopy: scanned, attempt: 2),
            .accepted)
    }
}

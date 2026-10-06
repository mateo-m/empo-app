import Foundation
import XCTest

@testable import GameProbe

/// What a partial snapshot does to the staleness clock, per SPEC
/// 7.2.
final class PartialPathClockTests: XCTestCase {

    private let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        root: EntryRoot = .container,
        path: String,
        partial: Bool,
        detectionSource: DetectionSource? = nil
    ) -> SnapshotManifest.Entry {
        SnapshotManifest.Entry(
            root: root,
            path: path,
            size: 10,
            modifiedAt: modifiedAt,
            hash: "abc",
            compression: .stored,
            partial: partial,
            detectionSource: detectionSource)
    }

    func testASnapshotWithNoPartialPathResetsTheClock() {
        let entries = [
            entry(path: "Game/Save01.rvdata2", partial: false, detectionSource: .classifier),
            entry(path: "Game/game.log", partial: false),
        ]
        XCTAssertTrue(PartialPathClock.resetsClock(entries: entries))
        XCTAssertEqual(PartialPathClock.savePartials(in: entries), [])
    }

    func testAPartialSaveMemberLeavesTheClockRunning() {
        for source in DetectionSource.allCases {
            let entries = [
                entry(path: "Game/Save01.rvdata2", partial: true, detectionSource: source)
            ]
            XCTAssertFalse(
                PartialPathClock.resetsClock(entries: entries),
                "a partial \(source.rawValue) match must leave the clock running")
        }
    }

    func testAPartialLogInAFullModeTreeResetsTheClock() {
        // No detection source and not an always-in path, so it is
        // not a save member. It only flags the snapshot incomplete.
        let entries = [
            entry(path: "Game/game.log", partial: true),
            entry(path: "Game/Save01.rvdata2", partial: false, detectionSource: .classifier),
        ]
        XCTAssertTrue(PartialPathClock.resetsClock(entries: entries))
    }

    func testAPartialSharedDataMemberLeavesTheClockRunning() {
        let entries = [entry(root: .sharedData, path: "Save/file.rxdata", partial: true)]
        XCTAssertFalse(PartialPathClock.resetsClock(entries: entries))
    }

    func testAPartialAlwaysInMemberLeavesTheClockRunning() {
        let entries = [entry(path: "EmpoState/backup.json", partial: true)]
        XCTAssertFalse(PartialPathClock.resetsClock(entries: entries))
    }

    // MARK: - The cause line

    func testTheSameSaveMemberPartialOnThreeRunsBecomesTheCauseLine() {
        var tally: [String: Int] = [:]
        for _ in 1...2 {
            tally = PartialPathClock.tally(tally, savePartials: ["Game/Save01.rvdata2"])
            XCTAssertNil(PartialPathClock.cause(tally))
        }
        tally = PartialPathClock.tally(tally, savePartials: ["Game/Save01.rvdata2"])
        XCTAssertEqual(PartialPathClock.cause(tally), .savesPartial(path: "Game/Save01.rvdata2"))
    }

    func testARunThatNoLongerReportsThePathClearsItsCount() {
        var tally: [String: Int] = [:]
        tally = PartialPathClock.tally(tally, savePartials: ["Game/Save01.rvdata2"])
        tally = PartialPathClock.tally(tally, savePartials: ["Game/Save01.rvdata2"])
        tally = PartialPathClock.tally(tally, savePartials: [])
        XCTAssertEqual(tally, [:])
        tally = PartialPathClock.tally(tally, savePartials: ["Game/Save01.rvdata2"])
        XCTAssertEqual(tally["Game/Save01.rvdata2"], 1)
    }

    func testTwoPathsAtThreeRunsNameTheFirstOneInOrder() {
        let tally = ["Game/b.rvdata2": 3, "Game/a.rvdata2": 4]
        XCTAssertEqual(PartialPathClock.cause(tally), .savesPartial(path: "Game/a.rvdata2"))
    }
}

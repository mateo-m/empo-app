import Foundation
import XCTest

@testable import GameProbe

final class RetentionPolicyTests: XCTestCase {

    /// 2026-05-01T00:00:00Z. Every date below is an offset from it,
    /// so the run does not depend on the day it happens.
    private let base = Date(timeIntervalSince1970: 1_777_593_600)

    /// 60 snapshots over 134 days:
    ///
    /// - 4 a day for the last 5 days, which is a week of play,
    /// - 1 a day for the 10 days before that,
    /// - 1 every 4 days for the 4 months before that.
    private lazy var stream: [DatedSnapshot] = {
        var offsets: [(day: Int, hour: Int)] = []
        for day in 0..<5 {
            for slot in 0..<4 { offsets.append((-day, 6 + 4 * slot)) }
        }
        for day in 5...14 { offsets.append((-day, 12)) }
        for step in 0..<30 { offsets.append((-(18 + 4 * step), 12)) }

        return offsets.enumerated().map { index, offset in
            let date = base.addingTimeInterval(
                Double(offset.day) * 86_400 + Double(offset.hour) * 3_600)
            return DatedSnapshot(
                id: BackupKeys.snapshotId(
                    date: date, suffix: String(format: "%06x", index)),
                date: date)
        }
    }()

    private func keep(_ preset: RetentionPreset) -> [String] {
        RetentionPolicy.plan(for: stream, kind: .game, preset: preset).keep
    }

    private func assertPlanCovers(
        _ plan: RetentionPlan, file: StaticString = #filePath, line: UInt = #line
    ) {
        let ids = stream.map(\.id).sorted()
        XCTAssertEqual(
            (plan.keep + plan.drop).sorted(), ids,
            "keep plus drop is the whole stream", file: file, line: line)
        XCTAssertTrue(
            Set(plan.keep).isDisjoint(with: Set(plan.drop)),
            "no id is on both lists", file: file, line: line)
    }

    func testTheStreamIs60SnapshotsOver4Months() {
        XCTAssertEqual(stream.count, 60)
        let oldest = stream.map(\.date).min() ?? base
        let newest = stream.map(\.date).max() ?? base
        XCTAssertEqual(Int(newest.timeIntervalSince(oldest) / 86_400), 134)
    }

    // MARK: - The exact keep set of each preset

    func testTheSmallPresetKeepsExactlyThese() {
        XCTAssertEqual(
            keep(.small),
            [
                "20260426T120000Z-000014",
                "20260429T180000Z-00000b",
                "20260430T180000Z-000007",
                "20260501T060000Z-000000",
                "20260501T100000Z-000001",
                "20260501T140000Z-000002",
                "20260501T180000Z-000003",
            ])
    }

    func testTheStandardPresetKeepsExactlyThese() {
        XCTAssertEqual(
            keep(.standard),
            [
                "20260409T120000Z-00001f",
                "20260419T120000Z-00001b",
                "20260425T120000Z-000015",
                "20260426T120000Z-000014",
                "20260427T180000Z-000013",
                "20260428T180000Z-00000f",
                "20260429T140000Z-00000a",
                "20260429T180000Z-00000b",
                "20260430T060000Z-000004",
                "20260430T100000Z-000005",
                "20260430T140000Z-000006",
                "20260430T180000Z-000007",
                "20260501T060000Z-000000",
                "20260501T100000Z-000001",
                "20260501T140000Z-000002",
                "20260501T180000Z-000003",
            ])
    }

    func testTheDeepPresetKeepsExactlyThese() {
        XCTAssertEqual(
            keep(.deep),
            [
                "20260312T120000Z-000026",
                "20260320T120000Z-000024",
                "20260328T120000Z-000022",
                "20260405T120000Z-000020",
                "20260409T120000Z-00001f",
                "20260418T120000Z-00001c",
                "20260419T120000Z-00001b",
                "20260420T120000Z-00001a",
                "20260421T120000Z-000019",
                "20260422T120000Z-000018",
                "20260423T120000Z-000017",
                "20260424T120000Z-000016",
                "20260425T120000Z-000015",
                "20260426T120000Z-000014",
                "20260427T060000Z-000010",
                "20260427T100000Z-000011",
                "20260427T140000Z-000012",
                "20260427T180000Z-000013",
                "20260428T060000Z-00000c",
                "20260428T100000Z-00000d",
                "20260428T140000Z-00000e",
                "20260428T180000Z-00000f",
                "20260429T060000Z-000008",
                "20260429T100000Z-000009",
                "20260429T140000Z-00000a",
                "20260429T180000Z-00000b",
                "20260430T060000Z-000004",
                "20260430T100000Z-000005",
                "20260430T140000Z-000006",
                "20260430T180000Z-000007",
                "20260501T060000Z-000000",
                "20260501T100000Z-000001",
                "20260501T140000Z-000002",
                "20260501T180000Z-000003",
            ])
    }

    func testEveryPresetSplitsTheWholeStream() {
        for preset in RetentionPreset.allCases {
            assertPlanCovers(
                RetentionPolicy.plan(for: stream, kind: .game, preset: preset))
        }
    }

    func testADeeperPresetKeepsEverythingAShallowerOneKeeps() {
        XCTAssertTrue(Set(keep(.small)).isSubset(of: Set(keep(.standard))))
        XCTAssertTrue(Set(keep(.standard)).isSubset(of: Set(keep(.deep))))
    }

    func testThePlanDoesNotDependOnTheInputOrder() {
        let shuffled = stream.shuffled()
        XCTAssertEqual(
            RetentionPolicy.plan(for: shuffled, kind: .game, preset: .standard),
            RetentionPolicy.plan(for: stream, kind: .game, preset: .standard))
    }

    // MARK: - The three stream kinds

    func testThePrefsStreamKeepsTheLastTen() {
        let plan = RetentionPolicy.plan(
            for: stream, kind: .preferences, preset: .standard)

        XCTAssertEqual(plan.keep.count, 10)
        XCTAssertEqual(plan.drop.count, 50)
        XCTAssertEqual(
            plan.keep,
            [
                "20260429T140000Z-00000a",
                "20260429T180000Z-00000b",
                "20260430T060000Z-000004",
                "20260430T100000Z-000005",
                "20260430T140000Z-000006",
                "20260430T180000Z-000007",
                "20260501T060000Z-000000",
                "20260501T100000Z-000001",
                "20260501T140000Z-000002",
                "20260501T180000Z-000003",
            ])
    }

    func testThePrefsStreamKeepsTheSameTenWhateverThePreset() {
        for preset in RetentionPreset.allCases {
            XCTAssertEqual(
                RetentionPolicy.plan(
                    for: stream, kind: .preferences, preset: preset
                ).keep.count, 10, "\(preset)")
        }
    }

    func testAGameWithNoContainerKeepsItsNewestThree() {
        let plan = RetentionPolicy.plan(
            for: stream, kind: .gameWithoutContainer, preset: .deep)

        XCTAssertEqual(
            plan.keep,
            [
                "20260501T100000Z-000001",
                "20260501T140000Z-000002",
                "20260501T180000Z-000003",
            ])
        XCTAssertEqual(plan.drop.count, 57)
    }

    func testTheThreeStreamKindsKeepDifferentCounts() {
        let game = RetentionPolicy.plan(for: stream, kind: .game, preset: .standard)
        let prefs = RetentionPolicy.plan(
            for: stream, kind: .preferences, preset: .standard)
        let deleted = RetentionPolicy.plan(
            for: stream, kind: .gameWithoutContainer, preset: .standard)

        XCTAssertEqual(game.keep.count, 16)
        XCTAssertEqual(prefs.keep.count, 10)
        XCTAssertEqual(deleted.keep.count, 3)
    }

    // MARK: - The ladders

    func testTheStandardGameLadderIsTheOneSection510States() {
        XCTAssertEqual(
            RetentionPolicy.ladder(kind: .game, preset: .standard),
            RetentionLadder(last: 10, daily: 7, weekly: 4))
        XCTAssertEqual(
            RetentionPolicy.ladder(kind: .preferences, preset: .standard),
            RetentionLadder(last: 10))
        XCTAssertEqual(
            RetentionPolicy.ladder(kind: .gameWithoutContainer, preset: .standard),
            RetentionLadder(last: 3))
    }

    // MARK: - Edges

    func testAStreamShorterThanTheLadderKeepsEverything() {
        let short = Array(stream.prefix(4))
        let plan = RetentionPolicy.plan(for: short, kind: .game, preset: .standard)

        XCTAssertEqual(plan.keep.count, 4)
        XCTAssertTrue(plan.drop.isEmpty)
    }

    func testAnEmptyStreamDropsNothing() {
        let plan = RetentionPolicy.plan(for: [], kind: .game, preset: .standard)

        XCTAssertTrue(plan.keep.isEmpty)
        XCTAssertTrue(plan.drop.isEmpty)
    }

    func testTwoSnapshotsOfOneSecondBreakTheTieById() {
        let date = base
        let pair = [
            DatedSnapshot(id: BackupKeys.snapshotId(date: date, suffix: "aaaaaa"), date: date),
            DatedSnapshot(id: BackupKeys.snapshotId(date: date, suffix: "bbbbbb"), date: date),
        ]
        let plan = RetentionPolicy.plan(for: pair, ladder: RetentionLadder(last: 1))

        XCTAssertEqual(plan.keep, [pair[1].id])
        XCTAssertEqual(plan.drop, [pair[0].id])
    }

    func testASnapshotDatesItselfFromItsId() {
        let date = Date(timeIntervalSince1970: 1_777_593_723)
        let id = BackupKeys.snapshotId(date: date, suffix: "0a1b2c")

        XCTAssertEqual(DatedSnapshot(id: id)?.date, date)
        XCTAssertNil(DatedSnapshot(id: "not-a-snapshot-id"))
    }
}

import Foundation
import XCTest

@testable import GameProbe

/// The order of SPEC 7.8: risk, then recency, then smallest pending
/// bytes.
final class RunOrderingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    // MARK: - Rule 1, risk

    func testAGameThatNeverHadASnapshotIsStale() {
        XCTAssertTrue(RunOrdering.isStale(lastSuccessAt: nil, now: now))
    }

    func testTheStaleMarkIsSevenDays() {
        XCTAssertEqual(RunOrdering.staleMark, 7 * 86_400)
        XCTAssertTrue(RunOrdering.isStale(lastSuccessAt: daysAgo(7), now: now))
        XCTAssertFalse(RunOrdering.isStale(lastSuccessAt: daysAgo(6.9), now: now))
    }

    func testStaleGamesLeadAndTheOldestOfThemGoesFirst() {
        let order = RunOrdering.order(
            [
                RunCandidate(gameKey: "fresh", lastSuccessAt: daysAgo(1)),
                RunCandidate(gameKey: "stale-8", lastSuccessAt: daysAgo(8)),
                RunCandidate(gameKey: "never", lastSuccessAt: nil),
                RunCandidate(gameKey: "stale-30", lastSuccessAt: daysAgo(30)),
            ],
            now: now)

        XCTAssertEqual(
            order.map(\.gameKey), ["never", "stale-30", "stale-8", "fresh"])
    }

    // MARK: - The three tiebreaks, in turn

    func testFiveDueGamesExerciseEveryTiebreak() {
        // One stale game leads on rule 1. The four fresh games then
        // break on recency, and the two that match on recency break
        // on pending bytes, and the two that match on both break on
        // the game key.
        let candidates = [
            RunCandidate(
                gameKey: "e-heavy", lastSuccessAt: daysAgo(1),
                lastPlayedAt: daysAgo(2), pendingBytes: 900),
            RunCandidate(
                gameKey: "b-light", lastSuccessAt: daysAgo(1),
                lastPlayedAt: daysAgo(2), pendingBytes: 10),
            RunCandidate(
                gameKey: "a-tie", lastSuccessAt: daysAgo(1),
                lastPlayedAt: daysAgo(3), pendingBytes: 50),
            RunCandidate(
                gameKey: "c-tie", lastSuccessAt: daysAgo(1),
                lastPlayedAt: daysAgo(3), pendingBytes: 50),
            RunCandidate(
                gameKey: "d-stale", lastSuccessAt: daysAgo(20),
                lastPlayedAt: daysAgo(19), pendingBytes: 4_000_000_000),
        ]

        let order = RunOrdering.order(candidates, now: now)

        XCTAssertEqual(
            order.map(\.gameKey),
            ["d-stale", "b-light", "e-heavy", "a-tie", "c-tie"])
    }

    func testRecencyBeatsPendingBytes() {
        let order = RunOrdering.order(
            [
                RunCandidate(
                    gameKey: "small-and-old", lastSuccessAt: daysAgo(1),
                    lastPlayedAt: daysAgo(9), pendingBytes: 1),
                RunCandidate(
                    gameKey: "big-and-recent", lastSuccessAt: daysAgo(1),
                    lastPlayedAt: daysAgo(1), pendingBytes: 4_000_000_000),
            ],
            now: now)

        XCTAssertEqual(order.map(\.gameKey), ["big-and-recent", "small-and-old"])
    }

    func testAGameNeverPlayedSortsLast() {
        let order = RunOrdering.order(
            [
                RunCandidate(gameKey: "never-played", lastSuccessAt: daysAgo(1)),
                RunCandidate(
                    gameKey: "played", lastSuccessAt: daysAgo(1),
                    lastPlayedAt: daysAgo(40)),
            ],
            now: now)

        XCTAssertEqual(order.map(\.gameKey), ["played", "never-played"])
    }

    func testTheOrderDoesNotDependOnTheInputOrder() {
        let candidates = (0..<6).map {
            RunCandidate(
                gameKey: "g\($0)", lastSuccessAt: daysAgo(1),
                lastPlayedAt: daysAgo(2), pendingBytes: 100)
        }
        let forward = RunOrdering.order(candidates, now: now).map(\.gameKey)
        let backward = RunOrdering.order(candidates.reversed(), now: now).map(\.gameKey)

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward, ["g0", "g1", "g2", "g3", "g4", "g5"])
    }
}

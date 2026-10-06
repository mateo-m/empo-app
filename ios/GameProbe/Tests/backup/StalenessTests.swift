import Foundation
import XCTest

@testable import GameProbe

/// The staleness clock of SPEC 7.1.
final class StalenessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    func testTheTwoMarksAreSevenAndTwentyOneDays() {
        XCTAssertEqual(Staleness.staleAfter, 7 * 86_400)
        XCTAssertEqual(Staleness.bannerAfter, 21 * 86_400)
    }

    // MARK: - One target

    func testAGameBackedUpAfterItsLastPlayIsFresh() {
        let target = TargetFreshness(
            targetId: "t1", lastSuccessAt: daysAgo(30), lastPlayedAt: daysAgo(40))
        XCTAssertNil(Staleness.unprotectedSince(target))
        XCTAssertEqual(Staleness.level(of: target, now: now), .fresh)
    }

    func testAGameNeverPlayedIsFresh() {
        let target = TargetFreshness(targetId: "t1", lastSuccessAt: nil, lastPlayedAt: nil)
        XCTAssertEqual(Staleness.level(of: target, now: now), .fresh)
    }

    func testAGamePlayedSinceItsSnapshotIsFreshInsideSevenDays() {
        let target = TargetFreshness(
            targetId: "t1", lastSuccessAt: daysAgo(6), lastPlayedAt: daysAgo(5))
        XCTAssertEqual(Staleness.level(of: target, now: now), .fresh)
    }

    func testItGoesStaleAtSevenDays() {
        let target = TargetFreshness(
            targetId: "t1", lastSuccessAt: daysAgo(7), lastPlayedAt: daysAgo(6))
        XCTAssertEqual(Staleness.level(of: target, now: now), .stale)
    }

    func testItReachesTheBannerAtTwentyOneDays() {
        let target = TargetFreshness(
            targetId: "t1", lastSuccessAt: daysAgo(21), lastPlayedAt: daysAgo(20))
        XCTAssertEqual(Staleness.level(of: target, now: now), .banner)
    }

    func testAGameThatNeverHadASnapshotCountsFromItsLastPlay() {
        let target = TargetFreshness(
            targetId: "t1", lastSuccessAt: nil, lastPlayedAt: daysAgo(8))
        XCTAssertEqual(Staleness.unprotectedSince(target), daysAgo(8))
        XCTAssertEqual(Staleness.level(of: target, now: now), .stale)
    }

    func testAPausedTargetLeavesThePromise() {
        let target = TargetFreshness(
            targetId: "t1", isPaused: true, lastSuccessAt: daysAgo(60),
            lastPlayedAt: daysAgo(30))
        XCTAssertEqual(Staleness.level(of: target, now: now), .fresh)
    }

    func testTheClockRunsWhileEmposOwnPolicyBlocksTheRun() {
        // Three weeks on cellular leaves the data as unprotected as
        // a dead token does, per 7.1.
        let target = TargetFreshness(
            targetId: "t1", lastSuccessAt: daysAgo(21), lastPlayedAt: daysAgo(20),
            cause: .waitingForWiFi)
        let freshness = Staleness.worst(gameKey: "g", of: [target], now: now)
        XCTAssertEqual(freshness.level, .banner)
        XCTAssertEqual(freshness.cause, .waitingForWiFi)
        XCTAssertEqual(freshness.cause?.line(targetLabel: "Dropbox"), "waiting for Wi-Fi")
    }

    // MARK: - The worst target

    func testTheBadgeShowsTheWorstOfThreeTargets() {
        let targets = [
            TargetFreshness(
                targetId: "fresh", lastSuccessAt: daysAgo(1), lastPlayedAt: daysAgo(2)),
            TargetFreshness(
                targetId: "stale", lastSuccessAt: daysAgo(9), lastPlayedAt: daysAgo(8),
                cause: .waitingForWiFi),
            TargetFreshness(
                targetId: "worst", lastSuccessAt: daysAgo(25), lastPlayedAt: daysAgo(24),
                cause: .needsSignIn),
        ]
        let freshness = Staleness.worst(gameKey: "g", of: targets, now: now)
        XCTAssertEqual(freshness.level, .banner)
        XCTAssertEqual(freshness.targetId, "worst")
        XCTAssertEqual(freshness.cause, .needsSignIn)
    }

    func testAPausedTargetNeverWinsTheBadge() {
        let targets = [
            TargetFreshness(
                targetId: "paused", isPaused: true, lastSuccessAt: daysAgo(90),
                lastPlayedAt: daysAgo(80), cause: .needsSignIn),
            TargetFreshness(
                targetId: "live", lastSuccessAt: daysAgo(9), lastPlayedAt: daysAgo(8),
                cause: .waitingForWiFi),
        ]
        let freshness = Staleness.worst(gameKey: "g", of: targets, now: now)
        XCTAssertEqual(freshness.level, .stale)
        XCTAssertEqual(freshness.targetId, "live")
    }

    func testEveryTargetPausedLeavesTheGameFresh() {
        let targets = [
            TargetFreshness(
                targetId: "a", isPaused: true, lastSuccessAt: daysAgo(90),
                lastPlayedAt: daysAgo(80)),
            TargetFreshness(
                targetId: "b", isPaused: true, lastSuccessAt: daysAgo(60),
                lastPlayedAt: daysAgo(50)),
        ]
        let freshness = Staleness.worst(gameKey: "g", of: targets, now: now)
        XCTAssertEqual(freshness.level, .fresh)
        XCTAssertNil(freshness.targetId)
    }

    func testTwoTargetsAtOneLevelBreakTheTieOnTheOlderClock() {
        let targets = [
            TargetFreshness(
                targetId: "newer", lastSuccessAt: daysAgo(8), lastPlayedAt: daysAgo(7)),
            TargetFreshness(
                targetId: "older", lastSuccessAt: daysAgo(12), lastPlayedAt: daysAgo(11)),
        ]
        XCTAssertEqual(
            Staleness.worst(gameKey: "g", of: targets, now: now).targetId, "older")
        XCTAssertEqual(
            Staleness.worst(gameKey: "g", of: targets.reversed(), now: now).targetId, "older")
    }

    // MARK: - The one banner

    func testTheLibraryShowsOneBannerAndNotOnePerGame() {
        let games = [
            GameFreshness(
                gameKey: "a", level: .banner, targetId: "t1", cause: .needsSignIn,
                unprotectedSince: daysAgo(30)),
            GameFreshness(
                gameKey: "b", level: .banner, targetId: "t1", cause: .needsSignIn,
                unprotectedSince: daysAgo(22)),
            GameFreshness(
                gameKey: "c", level: .stale, targetId: "t1", cause: .waitingForWiFi,
                unprotectedSince: daysAgo(8)),
        ]
        let banner = Staleness.libraryBanner(games)
        XCTAssertEqual(banner?.gameCount, 2)
        XCTAssertEqual(banner?.cause, .needsSignIn)
        XCTAssertEqual(banner?.action, .signInAgain)
        XCTAssertEqual(banner?.targetId, "t1")
    }

    func testNoGamePastTwentyOneDaysMeansNoBanner() {
        let games = [
            GameFreshness(gameKey: "a", level: .stale, unprotectedSince: daysAgo(8)),
            GameFreshness(gameKey: "b", level: .fresh),
        ]
        XCTAssertNil(Staleness.libraryBanner(games))
    }
}

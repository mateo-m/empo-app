import XCTest

@testable import GameProbe

final class BackupHistoryTests: XCTestCase {

    private let passStart = Date(timeIntervalSince1970: 1_000)

    private func run(startedAt: TimeInterval, finished: Bool, outcome: BackupRunOutcome = .failed)
        -> BackupRunRecord
    {
        BackupRunRecord(
            id: UUID().uuidString, targetId: "t", startedAt: Date(timeIntervalSince1970: startedAt),
            finishedAt: finished ? Date(timeIntervalSince1970: startedAt + 5) : nil,
            outcome: outcome, detail: BackupHistoryState.unfinishedLine)
    }

    func testTheRunInFlightReadsAsBackingUp() {
        let live = run(startedAt: 1_010, finished: false)
        XCTAssertEqual(BackupHistoryState.of(live, passStartedAt: passStart), .backingUp)
        XCTAssertEqual(BackupHistoryState.backingUp.title, "Backing up…")
    }

    func testAnUnfinishedRunFromAnEarlierPassDidNotFinish() {
        let crashed = run(startedAt: 900, finished: false)
        XCTAssertEqual(BackupHistoryState.of(crashed, passStartedAt: passStart), .failed)
        XCTAssertEqual(BackupHistoryState.of(crashed, passStartedAt: nil), .failed)
    }

    func testAFinishedRunKeepsItsOutcome() {
        let done = run(startedAt: 1_010, finished: true, outcome: .success)
        XCTAssertEqual(BackupHistoryState.of(done, passStartedAt: passStart), .success)
    }

    func testEveryStopLineIsASentence() {
        let stops: [BackupRunStop] = [
            .readOnlyFormat(.unreadableFormat), .needsSignIn, .offline, .serverError(status: 503),
            .throttled(retryAfter: 30), .gameStarted, .paused,
        ]
        for stop in stops {
            let line = SnapshotEngine.detail(of: stop)
            XCTAssertTrue(line.first?.isUppercase ?? false, line)
            XCTAssertTrue(line.hasSuffix("."), line)
            XCTAssertFalse(line.contains("route"), line)
            XCTAssertFalse(line.contains("503"), line)
        }
        XCTAssertTrue(BackupHistoryState.unfinishedLine.hasSuffix("."))
    }
}

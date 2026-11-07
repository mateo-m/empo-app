import XCTest

@testable import GameProbe

final class BackupHistoryTests: XCTestCase {

    private func run(_ id: String, end: BackupRunEnd? = nil) -> BackupRunRecord {
        BackupRunRecord(
            id: id, targetId: "t", startedAt: Date(timeIntervalSince1970: 1_000), end: end)
    }

    func testTheRunInFlightReadsAsBackingUp() {
        XCTAssertEqual(BackupHistoryState.of(run("live"), liveRunId: "live"), .backingUp)
        XCTAssertEqual(BackupHistoryState.backingUp.title, "Backing up…")
    }

    func testARowWithNoEndThatIsNotTheLiveRunDidNotFinish() {
        XCTAssertEqual(BackupHistoryState.of(run("crashed"), liveRunId: "live"), .failed)
        XCTAssertEqual(BackupHistoryState.of(run("crashed"), liveRunId: nil), .failed)
    }

    func testAFinishedRunKeepsItsOutcome() {
        let done = run(
            "live", end: BackupRunEnd(outcome: .success, finishedAt: Date(timeIntervalSince1970: 1_005)))
        XCTAssertEqual(BackupHistoryState.of(done, liveRunId: "live"), .success)
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
    }
}

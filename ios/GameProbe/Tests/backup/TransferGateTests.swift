import Foundation
import XCTest

@testable import GameProbe

/// A clock that records a wait and never sleeps.
actor FakeBackupClock: BackupClock {

    private(set) var waits: [TimeInterval] = []

    func wait(seconds: TimeInterval) async {
        waits.append(seconds)
    }
}

/// Counts how many times a transfer body ran.
actor AttemptCounter {

    private(set) var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

/// The in-flight limit and the throttle wait of SPEC 8.6.
final class TransferGateTests: XCTestCase {

    func testTheLimitIsFour() {
        XCTAssertEqual(TransferGate.maxInFlight, 4)
    }

    func testTheGateNeverHoldsMoreThanFourTransfersAtOnce() async {
        let gate = TransferGate()
        let latch = TransferLatch()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try? await gate.transfer { await latch.wait() }
                }
            }

            let arrived = await latch.waitForArrivals(4)
            XCTAssertTrue(arrived, "four transfers must reach the latch")

            // A fifth would mean five in flight. The latch holds
            // every arrival, so the count cannot grow past the
            // limit while the latch is shut.
            let held = await latch.arrivedCount
            XCTAssertEqual(held, 4)

            await latch.open()
        }

        let peak = await gate.peakInFlight
        XCTAssertEqual(peak, 4)
    }

    func testEveryTransferStillFinishesWhenMoreThanFourAreQueued() async {
        let gate = TransferGate()
        let counter = AttemptCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try? await gate.transfer { _ = await counter.next() }
                }
            }
        }

        let ran = await counter.count
        XCTAssertEqual(ran, 20)
    }

    func testTheGateHonorsRetryAfterAndNeverSleepsForReal() async {
        let clock = FakeBackupClock()
        let gate = TransferGate(attempts: 3, clock: clock)
        let counter = AttemptCounter()
        let startedAt = Date()

        do {
            try await gate.transfer { () async throws(BackupProviderError) in
                let attempt = await counter.next()
                if attempt < 3 { throw BackupProviderError.throttled(retryAfter: 7) }
            }
        } catch {
            XCTFail("the third try clears the throttle: \(error)")
        }

        let waits = await clock.waits
        XCTAssertEqual(waits, [7, 7])
        let recorded = await gate.waitedSeconds
        XCTAssertEqual(recorded, [7, 7])
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt), 2,
            "14 seconds of stated wait cost no real time")
    }

    func testAThrottleThatNeverClearsReachesTheEngine() async {
        let clock = FakeBackupClock()
        let gate = TransferGate(attempts: 3, clock: clock)

        do {
            try await gate.transfer { () async throws(BackupProviderError) in
                throw BackupProviderError.throttled(retryAfter: 5)
            }
            XCTFail("the gate must give up after its tries")
        } catch {
            // The engine waits the stated time and keeps the run,
            // per 8.4.
            XCTAssertEqual(error, .throttled(retryAfter: 5))
            XCTAssertEqual(error.effect, .waitAndKeepRun(seconds: 5))
        }

        let waits = await clock.waits
        XCTAssertEqual(waits, [5, 5])
    }

    func testAnErrorThatIsNotAThrottleRunsOnce() async {
        let clock = FakeBackupClock()
        let gate = TransferGate(attempts: 3, clock: clock)
        let counter = AttemptCounter()

        do {
            try await gate.transfer { () async throws(BackupProviderError) in
                _ = await counter.next()
                throw BackupProviderError.permissionDenied
            }
            XCTFail("the error must reach the caller")
        } catch {
            XCTAssertEqual(error, .permissionDenied)
        }

        let ran = await counter.count
        XCTAssertEqual(ran, 1)
        let waits = await clock.waits
        XCTAssertTrue(waits.isEmpty)
    }

    func testACallThatMovesNoFileWaitsWithoutTakingASlot() async {
        let clock = FakeBackupClock()
        let gate = TransferGate(attempts: 3, clock: clock)
        let counter = AttemptCounter()

        do {
            try await gate.request { () async throws(BackupProviderError) in
                let attempt = await counter.next()
                if attempt < 3 { throw BackupProviderError.throttled(retryAfter: 4) }
            }
        } catch {
            XCTFail("the third try clears the throttle: \(error)")
        }

        let waits = await clock.waits
        XCTAssertEqual(waits, [4, 4])
        // `list`, `delete`, and `quota` move no file, so the limit
        // of four never counts them.
        let peak = await gate.peakInFlight
        XCTAssertEqual(peak, 0)
    }

    func testAnyNumberOfRequestsRunAtOnce() async {
        let gate = TransferGate()
        let latch = TransferLatch()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try? await gate.request { await latch.wait() }
                }
            }

            let arrived = await latch.waitForArrivals(12)
            XCTAssertTrue(arrived, "no request waits on a transfer slot")

            await latch.open()
        }

        let peak = await gate.peakInFlight
        XCTAssertEqual(peak, 0)
    }

    func testATransferThatThrottlesGivesItsSlotUpWhileItWaits() async {
        let clock = FakeBackupClock()
        let gate = TransferGate(attempts: 2, clock: clock)

        // One throttled transfer must not hold a slot through its
        // wait, or a target that throttles once would run at three.
        try? await gate.transfer { () async throws(BackupProviderError) in
            throw BackupProviderError.throttled(retryAfter: 1)
        }

        let peak = await gate.peakInFlight
        XCTAssertEqual(peak, 1)
    }
}

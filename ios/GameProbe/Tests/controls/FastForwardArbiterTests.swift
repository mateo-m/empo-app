import XCTest

@testable import GameProbe

final class FastForwardArbiterTests: XCTestCase {

    func testHoldPressAndRelease() {
        var arbiter = FastForwardArbiter()
        XCTAssertEqual(arbiter.holdPressed(configuredMultiplier: 4, bridgeMultiplier: 1), 4)
        XCTAssertEqual(arbiter.holdCount, 1)
        XCTAssertEqual(arbiter.holdReleased(configuredMultiplier: 4, bridgeMultiplier: 4), 1)
        XCTAssertEqual(arbiter.holdCount, 0)
    }

    func testNestedHoldsReleaseOnce() {
        var arbiter = FastForwardArbiter()
        XCTAssertEqual(arbiter.holdPressed(configuredMultiplier: 2, bridgeMultiplier: 1), 2)
        XCTAssertEqual(arbiter.holdPressed(configuredMultiplier: 2, bridgeMultiplier: 2), 2)
        XCTAssertNil(arbiter.holdReleased(configuredMultiplier: 2, bridgeMultiplier: 2))
        XCTAssertEqual(arbiter.holdReleased(configuredMultiplier: 2, bridgeMultiplier: 2), 1)
    }

    func testLatchWinsOverHoldRelease() {
        var arbiter = FastForwardArbiter()
        _ = arbiter.holdPressed(configuredMultiplier: 4, bridgeMultiplier: 1)
        // Toggling during the hold arms the latch.
        XCTAssertEqual(arbiter.toggled(configuredMultiplier: 4, bridgeMultiplier: 4), 4)
        // Releasing the hold keeps the speed on: latch wins.
        XCTAssertEqual(arbiter.holdReleased(configuredMultiplier: 4, bridgeMultiplier: 4), 4)
        XCTAssertTrue(arbiter.latched)
        // The next toggle turns it off.
        XCTAssertEqual(arbiter.toggled(configuredMultiplier: 4, bridgeMultiplier: 4), 1)
        XCTAssertFalse(arbiter.latched)
    }

    func testToggleDerivesFromBridge() {
        var arbiter = FastForwardArbiter()
        // The bridge says the engine is already fast (external state):
        // the toggle must turn it OFF, not mirror a stale cached flag.
        XCTAssertEqual(arbiter.toggled(configuredMultiplier: 2, bridgeMultiplier: 4), 1)
        XCTAssertFalse(arbiter.latched)
        // Bridge idle: toggle turns it on.
        XCTAssertEqual(arbiter.toggled(configuredMultiplier: 2, bridgeMultiplier: 1), 2)
        XCTAssertTrue(arbiter.latched)
    }

    func testUnconfiguredGameIsInert() {
        var arbiter = FastForwardArbiter()
        XCTAssertNil(arbiter.holdPressed(configuredMultiplier: nil, bridgeMultiplier: 1))
        XCTAssertEqual(arbiter.holdCount, 0)
        // A toggle on an unconfigured game only stops a running engine.
        XCTAssertNil(arbiter.toggled(configuredMultiplier: nil, bridgeMultiplier: 1))
        XCTAssertEqual(arbiter.toggled(configuredMultiplier: nil, bridgeMultiplier: 4), 1)
    }

    func testReleaseAllHolds() {
        var arbiter = FastForwardArbiter()
        _ = arbiter.holdPressed(configuredMultiplier: 3, bridgeMultiplier: 1)
        _ = arbiter.holdPressed(configuredMultiplier: 3, bridgeMultiplier: 3)
        XCTAssertEqual(arbiter.releaseAllHolds(configuredMultiplier: 3, bridgeMultiplier: 3), 1)
        XCTAssertEqual(arbiter.holdCount, 0)
        // Nothing held: no write.
        XCTAssertNil(arbiter.releaseAllHolds(configuredMultiplier: 3, bridgeMultiplier: 1))
    }

    func testReleaseAllHoldsKeepsLatch() {
        var arbiter = FastForwardArbiter()
        _ = arbiter.holdPressed(configuredMultiplier: 3, bridgeMultiplier: 1)
        _ = arbiter.toggled(configuredMultiplier: 3, bridgeMultiplier: 3)
        XCTAssertEqual(arbiter.releaseAllHolds(configuredMultiplier: 3, bridgeMultiplier: 3), 3)
        XCTAssertTrue(arbiter.latched)
    }

    func testReconcileAdoptsBridgeWhenIdle() {
        var arbiter = FastForwardArbiter()
        // Engine fast, settings allow it: adopt, push configured value
        // back so an in-pause settings edit takes effect.
        let adopted = arbiter.reconcile(configuredMultiplier: 2, bridgeMultiplier: 4)
        XCTAssertEqual(adopted.write, 2)
        XCTAssertTrue(adopted.active)
        XCTAssertTrue(arbiter.latched)
        // Engine fast, settings cleared: stop it.
        var cleared = FastForwardArbiter()
        let stopped = cleared.reconcile(configuredMultiplier: nil, bridgeMultiplier: 4)
        XCTAssertEqual(stopped.write, 1)
        XCTAssertFalse(stopped.active)
        // Engine idle: nothing to write.
        var idle = FastForwardArbiter()
        let none = idle.reconcile(configuredMultiplier: 2, bridgeMultiplier: 1)
        XCTAssertNil(none.write)
        XCTAssertFalse(none.active)
        // Engine idle AND settings cleared: still nothing to write.
        var clearedIdle = FastForwardArbiter()
        let quiet = clearedIdle.reconcile(configuredMultiplier: nil, bridgeMultiplier: 1)
        XCTAssertNil(quiet.write)
        XCTAssertFalse(quiet.active)
    }

    func testReconcileDuringHoldReportsBridgeActivity() {
        var arbiter = FastForwardArbiter()
        _ = arbiter.holdPressed(configuredMultiplier: 4, bridgeMultiplier: 1)
        // Bridge idle mid-hold (engine already reset): active is false.
        let outcome = arbiter.reconcile(configuredMultiplier: 4, bridgeMultiplier: 1)
        XCTAssertNil(outcome.write)
        XCTAssertFalse(outcome.active)
    }

    func testToggleDisarmsDuringHold() {
        var arbiter = FastForwardArbiter()
        _ = arbiter.holdPressed(configuredMultiplier: 4, bridgeMultiplier: 1)
        _ = arbiter.toggled(configuredMultiplier: 4, bridgeMultiplier: 4)
        // The second toggle during the same hold disarms the latch.
        XCTAssertEqual(arbiter.toggled(configuredMultiplier: 4, bridgeMultiplier: 4), 4)
        XCTAssertFalse(arbiter.latched)
        XCTAssertEqual(arbiter.holdReleased(configuredMultiplier: 4, bridgeMultiplier: 4), 1)
    }

    func testLatchResetsWhenConfigClearsOnRelease() {
        var arbiter = FastForwardArbiter()
        _ = arbiter.holdPressed(configuredMultiplier: 4, bridgeMultiplier: 1)
        _ = arbiter.toggled(configuredMultiplier: 4, bridgeMultiplier: 4)
        // Settings cleared mid-hold: the release must stop the engine
        // and drop the latch, not keep a speed the game no longer allows.
        XCTAssertEqual(arbiter.holdReleased(configuredMultiplier: nil, bridgeMultiplier: 4), 1)
        XCTAssertFalse(arbiter.latched)

        var all = FastForwardArbiter()
        _ = all.holdPressed(configuredMultiplier: 4, bridgeMultiplier: 1)
        _ = all.toggled(configuredMultiplier: 4, bridgeMultiplier: 4)
        XCTAssertEqual(all.releaseAllHolds(configuredMultiplier: nil, bridgeMultiplier: 4), 1)
        XCTAssertFalse(all.latched)
    }

    func testConfiguredBelowTwoIsInert() {
        var arbiter = FastForwardArbiter()
        XCTAssertNil(arbiter.holdPressed(configuredMultiplier: 1, bridgeMultiplier: 1))
        XCTAssertEqual(arbiter.holdCount, 0)
        XCTAssertNil(arbiter.toggled(configuredMultiplier: 0, bridgeMultiplier: 1))
        XCTAssertFalse(arbiter.latched)
    }

    func testSpuriousHoldReleaseIsIgnored() {
        var arbiter = FastForwardArbiter()
        XCTAssertNil(arbiter.holdReleased(configuredMultiplier: 4, bridgeMultiplier: 1))
        XCTAssertEqual(arbiter.holdCount, 0)
    }

    func testLatchClearedNeverArms() {
        // The More sheet's Toggle set to OFF during a hold: the latch
        // clears, the speed stays owned by the hold, and the later
        // release stops the engine.
        var arbiter = FastForwardArbiter()
        _ = arbiter.holdPressed(configuredMultiplier: 4, bridgeMultiplier: 1)
        _ = arbiter.toggled(configuredMultiplier: 4, bridgeMultiplier: 4)
        XCTAssertNil(arbiter.latchCleared(bridgeMultiplier: 4))
        XCTAssertFalse(arbiter.latched)
        XCTAssertEqual(arbiter.holdReleased(configuredMultiplier: 4, bridgeMultiplier: 4), 1)

        // No hold, engine running: clearing the latch stops it.
        var idle = FastForwardArbiter()
        _ = idle.toggled(configuredMultiplier: 4, bridgeMultiplier: 1)
        XCTAssertEqual(idle.latchCleared(bridgeMultiplier: 4), 1)
        XCTAssertFalse(idle.latched)
        // Already off: nothing to write.
        XCTAssertNil(idle.latchCleared(bridgeMultiplier: 1))
    }

    func testReconcileDoesNotAdoptDuringHold() {
        var arbiter = FastForwardArbiter()
        _ = arbiter.holdPressed(configuredMultiplier: 4, bridgeMultiplier: 1)
        // A legitimate in-progress hold must not convert into a latch
        // when a sheet opens and triggers a reconcile.
        let outcome = arbiter.reconcile(configuredMultiplier: 4, bridgeMultiplier: 4)
        XCTAssertNil(outcome.write)
        XCTAssertTrue(outcome.active)
        XCTAssertFalse(arbiter.latched)
        XCTAssertEqual(arbiter.holdReleased(configuredMultiplier: 4, bridgeMultiplier: 4), 1)
    }
}

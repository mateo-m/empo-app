import XCTest

@testable import GameProbe

final class ControlTouchSetTests: XCTestCase {

    /// An idle set tracks NOTHING. `isTracking` must not default to
    /// permissive when no touch is live, or late move samples from a
    /// lifted finger would keep flowing after touch-end.
    func testIdleSetTracksNothing() {
        let touches = ControlTouchSet<String>()
        XCTAssertFalse(touches.isEngaged)
        XCTAssertEqual(touches.live, [])
        XCTAssertFalse(touches.isTracking("a"))
    }

    /// The first finger reports the idle -> engaged transition, which
    /// is where a button emits its key-down.
    func testFirstTouchEngagesTheControl() {
        var touches = ControlTouchSet<String>()
        XCTAssertTrue(touches.begin("a"))
        XCTAssertTrue(touches.isEngaged)
        XCTAssertTrue(touches.isTracking("a"))
    }

    /// A second finger on the same control is TRACKED, but it must
    /// not report a second engagement. A button must not press twice
    /// and the pad must not restart its sequence.
    func testSecondTouchJoinsWithoutRepeatingTheEngagement() {
        var touches = ControlTouchSet<String>()
        XCTAssertTrue(touches.begin("a"))
        XCTAssertFalse(touches.begin("b"))
        XCTAssertEqual(touches.live, ["a", "b"])
        XCTAssertTrue(touches.isTracking("a"))
        XCTAssertTrue(touches.isTracking("b"))
    }

    /// A duplicate begin is rejected outright: it must neither
    /// re-fire touch-down side effects nor list the finger twice
    /// (which would take two lifts to clear).
    func testReBeginningALiveTouchIsRejected() {
        var touches = ControlTouchSet<String>()
        XCTAssertTrue(touches.begin("a"))
        XCTAssertFalse(touches.begin("a"))
        XCTAssertEqual(touches.live, ["a"])
        XCTAssertEqual(touches.end("a"), .idle)
    }

    /// THE regression this type exists to guard: with two fingers
    /// down, the first one lifting must NOT end the control. The
    /// button stays held, and the D-pad keeps the direction the
    /// second finger holds.
    func testControlSurvivesTheFirstOfTwoTouchesLifting() {
        var touches = ControlTouchSet<String>()
        _ = touches.begin("a")
        _ = touches.begin("b")
        XCTAssertEqual(touches.end("a"), .stillEngaged)
        XCTAssertTrue(touches.isEngaged)
        XCTAssertEqual(touches.live, ["b"])
        // The last finger closes it.
        XCTAssertEqual(touches.end("b"), .idle)
        XCTAssertFalse(touches.isEngaged)
    }

    /// An unknown touch lifting must not release the control, that
    /// would drop held keys while a real finger is still down.
    func testUnknownTouchEndingChangesNothing() {
        var touches = ControlTouchSet<String>()
        _ = touches.begin("a")
        XCTAssertEqual(touches.end("b"), .notTracked)
        XCTAssertEqual(touches.live, ["a"])
        XCTAssertTrue(touches.isTracking("a"))
    }

    func testLastTouchEndingReleasesExactlyOnce() {
        var touches = ControlTouchSet<String>()
        XCTAssertTrue(touches.begin("a"))
        XCTAssertEqual(touches.end("a"), .idle)
        XCTAssertFalse(touches.isEngaged)
        // The lifted finger's late move samples must be rejected too.
        XCTAssertFalse(touches.isTracking("a"))
        // touchesEnded and touchesCancelled can both arrive for one
        // touch. The second must be a no-op, not a second release.
        XCTAssertEqual(touches.end("a"), .notTracked)
    }

    func testEndWhileIdleIsRejected() {
        var touches = ControlTouchSet<String>()
        XCTAssertEqual(touches.end("a"), .notTracked)
        XCTAssertFalse(touches.isEngaged)
    }

    func testSetIsReusableAfterRelease() {
        var touches = ControlTouchSet<String>()
        XCTAssertTrue(touches.begin("a"))
        XCTAssertEqual(touches.end("a"), .idle)
        XCTAssertTrue(touches.begin("b"))
        XCTAssertTrue(touches.isTracking("b"))
        XCTAssertFalse(touches.isTracking("a"))
    }

    /// Host-driven cancellation (control disabled or torn down
    /// mid-touch): reset hands back every live touch, oldest first,
    /// so the caller can close each one exactly as a lift would.
    func testResetReturnsEveryLiveTouchOldestFirst() {
        var touches = ControlTouchSet<String>()
        _ = touches.begin("a")
        _ = touches.begin("b")
        XCTAssertEqual(touches.reset(), ["a", "b"])
        XCTAssertFalse(touches.isEngaged)
        // Nothing is tracked anymore: repeat resets are no-ops, and
        // the dead touches' own late ends must not fire again.
        XCTAssertEqual(touches.reset(), [])
        XCTAssertEqual(touches.end("a"), .notTracked)
        XCTAssertEqual(touches.end("b"), .notTracked)
    }

    func testResetWhileIdleReportsNothingToCancel() {
        var touches = ControlTouchSet<String>()
        XCTAssertEqual(touches.reset(), [])
        XCTAssertFalse(touches.isEngaged)
    }

    func testSetIsReusableAfterReset() {
        var touches = ControlTouchSet<String>()
        XCTAssertTrue(touches.begin("a"))
        XCTAssertEqual(touches.reset(), ["a"])
        XCTAssertTrue(touches.begin("b"))
        XCTAssertTrue(touches.isTracking("b"))
    }
}

final class ControlHitShapeTests: XCTestCase {

    /// 150x150 control: circle of radius 75 centered at (75, 75).
    func testSquareBoundsInscribedCircle() {
        XCTAssertTrue(ControlHitShape.circleContains(width: 150, height: 150, x: 75, y: 75))
        // Cardinal boundary points sit at distance exactly 75:
        // boundary is inclusive.
        XCTAssertTrue(ControlHitShape.circleContains(width: 150, height: 150, x: 150, y: 75))
        XCTAssertTrue(ControlHitShape.circleContains(width: 150, height: 150, x: 75, y: 0))
        // One point past the rim along an axis.
        XCTAssertFalse(ControlHitShape.circleContains(width: 150, height: 150, x: 151, y: 75))
        XCTAssertFalse(ControlHitShape.circleContains(width: 150, height: 150, x: 75, y: -1))
    }

    /// The frame's corners are NOT hit-testable. Corner touches fall
    /// through to whatever sits below the control. (3-4-5 triangle:
    /// (120, 135) is at distance exactly 75, inside. The corner at
    /// distance 75 * sqrt(2) is far outside.)
    func testCornersFallOutsideTheCircle() {
        XCTAssertFalse(ControlHitShape.circleContains(width: 150, height: 150, x: 0, y: 0))
        XCTAssertFalse(ControlHitShape.circleContains(width: 150, height: 150, x: 150, y: 150))
        XCTAssertFalse(ControlHitShape.circleContains(width: 150, height: 150, x: 4, y: 4))
        XCTAssertTrue(ControlHitShape.circleContains(width: 150, height: 150, x: 120, y: 135))
        XCTAssertFalse(ControlHitShape.circleContains(width: 150, height: 150, x: 121, y: 136))
    }

    /// Non-square bounds use the SHORTER side for the radius, still
    /// centered in the full box. Both aspect ratios are pinned.
    /// "shorter side" implemented as either fixed axis passes the
    /// other orientation.
    func testNonSquareBoundsUseShorterSide() {
        // 100x60 (wide): radius 30, center (50, 30).
        XCTAssertTrue(ControlHitShape.circleContains(width: 100, height: 60, x: 80, y: 30))
        XCTAssertFalse(ControlHitShape.circleContains(width: 100, height: 60, x: 81, y: 30))
        XCTAssertTrue(ControlHitShape.circleContains(width: 100, height: 60, x: 50, y: 0))
        XCTAssertTrue(ControlHitShape.circleContains(width: 100, height: 60, x: 50, y: 60))
        XCTAssertFalse(ControlHitShape.circleContains(width: 100, height: 60, x: 20, y: 8))

        // 60x100 (tall): radius 30, center (30, 50).
        XCTAssertTrue(ControlHitShape.circleContains(width: 60, height: 100, x: 30, y: 80))
        XCTAssertFalse(ControlHitShape.circleContains(width: 60, height: 100, x: 30, y: 81))
        XCTAssertTrue(ControlHitShape.circleContains(width: 60, height: 100, x: 0, y: 50))
        XCTAssertTrue(ControlHitShape.circleContains(width: 60, height: 100, x: 60, y: 50))
        XCTAssertFalse(ControlHitShape.circleContains(width: 60, height: 100, x: 8, y: 20))
    }
}

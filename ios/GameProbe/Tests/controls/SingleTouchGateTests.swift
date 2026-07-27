import XCTest

@testable import GameProbe

final class SingleTouchGateTests: XCTestCase {

    func testFirstTouchClaimsTheGate() {
        var gate = SingleTouchGate<String>()
        XCTAssertTrue(gate.begin("a"))
        XCTAssertEqual(gate.tracked, "a")
        XCTAssertTrue(gate.isTracking("a"))
    }

    /// A second finger landing on the same control must not steal or
    /// restart the sequence: it is rejected, and the original touch
    /// keeps flowing.
    func testSecondTouchIsRejectedWhileTracking() {
        var gate = SingleTouchGate<String>()
        XCTAssertTrue(gate.begin("a"))
        XCTAssertFalse(gate.begin("b"))
        XCTAssertEqual(gate.tracked, "a")
        XCTAssertTrue(gate.isTracking("a"))
        XCTAssertFalse(gate.isTracking("b"))
    }

    /// Beginning the tracked touch again is also a rejection — a
    /// duplicate begin must not re-fire touch-down side effects.
    func testReBeginningTheTrackedTouchIsRejected() {
        var gate = SingleTouchGate<String>()
        XCTAssertTrue(gate.begin("a"))
        XCTAssertFalse(gate.begin("a"))
        XCTAssertEqual(gate.tracked, "a")
    }

    /// The rejected second finger lifting must NOT end the sequence —
    /// that would release held keys while the first finger is still
    /// down (the classic stuck-walk / dropped-hold bug).
    func testUntrackedTouchEndingDoesNotReleaseTheGate() {
        var gate = SingleTouchGate<String>()
        XCTAssertTrue(gate.begin("a"))
        XCTAssertFalse(gate.end("b"))
        XCTAssertEqual(gate.tracked, "a")
        XCTAssertTrue(gate.isTracking("a"))
    }

    func testTrackedTouchEndingReleasesExactlyOnce() {
        var gate = SingleTouchGate<String>()
        XCTAssertTrue(gate.begin("a"))
        XCTAssertTrue(gate.end("a"))
        XCTAssertNil(gate.tracked)
        // touchesEnded and touchesCancelled can both arrive for one
        // touch; the second must be a no-op, not a second release.
        XCTAssertFalse(gate.end("a"))
    }

    func testEndWhileIdleIsRejected() {
        var gate = SingleTouchGate<String>()
        XCTAssertFalse(gate.end("a"))
        XCTAssertNil(gate.tracked)
    }

    func testGateIsReusableAfterRelease() {
        var gate = SingleTouchGate<String>()
        XCTAssertTrue(gate.begin("a"))
        XCTAssertTrue(gate.end("a"))
        XCTAssertTrue(gate.begin("b"))
        XCTAssertTrue(gate.isTracking("b"))
        XCTAssertFalse(gate.isTracking("a"))
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

    /// The frame's corners are NOT hit-testable — corner touches fall
    /// through to whatever sits below the control. (3-4-5 triangle:
    /// (120, 135) is at distance exactly 75, inside; the corner at
    /// distance 75 * sqrt(2) is far outside.)
    func testCornersFallOutsideTheCircle() {
        XCTAssertFalse(ControlHitShape.circleContains(width: 150, height: 150, x: 0, y: 0))
        XCTAssertFalse(ControlHitShape.circleContains(width: 150, height: 150, x: 150, y: 150))
        XCTAssertFalse(ControlHitShape.circleContains(width: 150, height: 150, x: 4, y: 4))
        XCTAssertTrue(ControlHitShape.circleContains(width: 150, height: 150, x: 120, y: 135))
        XCTAssertFalse(ControlHitShape.circleContains(width: 150, height: 150, x: 121, y: 136))
    }

    /// Non-square bounds use the SHORTER side for the radius, still
    /// centered in the full box.
    func testNonSquareBoundsUseShorterSide() {
        // 100x60: radius 30, center (50, 30).
        XCTAssertTrue(ControlHitShape.circleContains(width: 100, height: 60, x: 80, y: 30))
        XCTAssertFalse(ControlHitShape.circleContains(width: 100, height: 60, x: 81, y: 30))
        XCTAssertTrue(ControlHitShape.circleContains(width: 100, height: 60, x: 50, y: 0))
        XCTAssertTrue(ControlHitShape.circleContains(width: 100, height: 60, x: 50, y: 60))
        XCTAssertFalse(ControlHitShape.circleContains(width: 100, height: 60, x: 20, y: 8))
    }
}

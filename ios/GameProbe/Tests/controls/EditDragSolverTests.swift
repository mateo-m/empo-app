import XCTest

@testable import GameProbe

/// The solver's contract: a dragged circle never enters an obstacle,
/// never tunnels to the far side, and always exits a wall toward the
/// side the drag came from.
final class EditDragSolverTests: XCTestCase {
    private typealias Solver = EditDragSolver

    private func distance(
        _ x: Double, _ y: Double, _ circle: EditDragSolver.Circle
    ) -> Double {
        let dx = x - circle.x
        let dy = y - circle.y
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Circle obstacles

    func testNoCollisionReturnsDesiredPoint() {
        let obstacle = Solver.Circle(x: 100, y: 100, radius: 28)
        let result = Solver.resolvedCenter(
            desiredX: 300, desiredY: 300, previousX: 290, previousY: 300,
            radius: 28, obstacles: [obstacle], walls: [])
        XCTAssertEqual(result.x, 300)
        XCTAssertEqual(result.y, 300)
    }

    func testOverlapPushesOutToTheRim() {
        let obstacle = Solver.Circle(x: 100, y: 100, radius: 28)
        let result = Solver.resolvedCenter(
            desiredX: 130, desiredY: 100, previousX: 160, previousY: 100,
            radius: 28, obstacles: [obstacle], walls: [])
        XCTAssertEqual(distance(result.x, result.y, obstacle), 56, accuracy: 0.01)
        XCTAssertGreaterThan(result.x, obstacle.x)
    }

    func testPointerCrossingCenterDoesNotTunnel() {
        // The drag approaches from the right; the pointer lands PAST
        // the obstacle's center on the far (left) side. Side memory
        // must keep the circle on the right rim.
        let obstacle = Solver.Circle(x: 100, y: 100, radius: 28)
        let result = Solver.resolvedCenter(
            desiredX: 90, desiredY: 100, previousX: 156, previousY: 100,
            radius: 28, obstacles: [obstacle], walls: [])
        XCTAssertGreaterThan(result.x, obstacle.x, "tunneled to the approach's far side")
        XCTAssertEqual(distance(result.x, result.y, obstacle), 56, accuracy: 0.01)
    }

    func testPointerExactlyOnCenterHoldsTheApproachSide() {
        let obstacle = Solver.Circle(x: 100, y: 100, radius: 28)
        let result = Solver.resolvedCenter(
            desiredX: 100, desiredY: 100, previousX: 156, previousY: 100,
            radius: 28, obstacles: [obstacle], walls: [])
        XCTAssertGreaterThan(result.x, obstacle.x)
        XCTAssertEqual(distance(result.x, result.y, obstacle), 56, accuracy: 0.01)
    }

    func testDeadCenterWithoutPreviousPushesUp() {
        let obstacle = Solver.Circle(x: 100, y: 100, radius: 28)
        let result = Solver.resolvedCenter(
            desiredX: 100, desiredY: 100, previousX: nil, previousY: nil,
            radius: 28, obstacles: [obstacle], walls: [])
        XCTAssertEqual(result.x, 100, accuracy: 0.01)
        XCTAssertEqual(result.y, 100 - 56, accuracy: 0.01)
    }

    func testImpossibleGapStillReportsCollisionForTheRejectStep() {
        // Two obstacles with a gap narrower than the dragged circle:
        // no clean position exists between them, so the solve cannot
        // land clean. The contract is the PIPELINE's: `collides`
        // must report the unresolved result, so the caller rejects
        // the update and holds the last valid position.
        let left = Solver.Circle(x: 100, y: 100, radius: 28)
        let right = Solver.Circle(x: 190, y: 100, radius: 28)
        let result = Solver.resolvedCenter(
            desiredX: 145, desiredY: 100, previousX: 145, previousY: 30,
            radius: 28, obstacles: [left, right], walls: [])
        XCTAssertTrue(
            Solver.collides(
                x: result.x, y: result.y, radius: 28,
                obstacles: [left, right], walls: []),
            "an unresolvable solve must stay visible to the reject step")
        // The held position (the drag's previous point) stays valid.
        XCTAssertFalse(
            Solver.collides(x: 145, y: 30, radius: 28, obstacles: [left, right], walls: []))
    }

    func testSettlingIntoAWideEnoughGapEndsClean() {
        // The same shape with room between the rims: the iterated
        // solve must settle collision-free.
        let left = Solver.Circle(x: 100, y: 100, radius: 28)
        let right = Solver.Circle(x: 220, y: 100, radius: 28)
        let result = Solver.resolvedCenter(
            desiredX: 160, desiredY: 100, previousX: 160, previousY: 30,
            radius: 28, obstacles: [left, right], walls: [])
        XCTAssertFalse(
            Solver.collides(
                x: result.x, y: result.y, radius: 28,
                obstacles: [left, right], walls: []))
    }

    // MARK: - Wall rectangles

    func testWallPushesOutTowardNearestEdgeWithoutPrevious() {
        let wall = Solver.Rect(x: 100, y: 100, width: 200, height: 40)
        let result = Solver.resolvedCenter(
            desiredX: 110, desiredY: 120, previousX: nil, previousY: nil,
            radius: 20, obstacles: [], walls: [wall])
        XCTAssertFalse(
            Solver.collides(x: result.x, y: result.y, radius: 20, obstacles: [], walls: [wall])
        )
    }

    func testWallExitPrefersTheApproachSide() {
        // The drag comes from above the wall; the pointer dives deep
        // into it. The exit must go back UP, not out the nearest edge.
        let wall = Solver.Rect(x: 100, y: 100, width: 200, height: 60)
        let result = Solver.resolvedCenter(
            desiredX: 200, desiredY: 150, previousX: 200, previousY: 60,
            radius: 20, obstacles: [], walls: [wall])
        XCTAssertEqual(result.y, 100 - 20, accuracy: 0.01)
        XCTAssertEqual(result.x, 200, accuracy: 0.01)
    }

    // MARK: - Collision test

    func testCollidesUsesRimSlack() {
        let obstacle = Solver.Circle(x: 100, y: 100, radius: 28)
        // Exactly on the rim: NOT a collision (slack absorbs noise).
        XCTAssertFalse(
            Solver.collides(x: 156, y: 100, radius: 28, obstacles: [obstacle], walls: []))
        // A point clearly inside: collision.
        XCTAssertTrue(
            Solver.collides(x: 150, y: 100, radius: 28, obstacles: [obstacle], walls: []))
    }

    func testCollidesAgainstWalls() {
        let wall = Solver.Rect(x: 100, y: 100, width: 200, height: 40)
        XCTAssertTrue(
            Solver.collides(x: 110, y: 120, radius: 20, obstacles: [], walls: [wall]))
        XCTAssertFalse(
            Solver.collides(x: 110, y: 190, radius: 20, obstacles: [], walls: [wall]))
    }
}

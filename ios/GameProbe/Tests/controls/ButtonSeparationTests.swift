import XCTest

@testable import GameProbe

final class ButtonSeparationTests: XCTestCase {

    func testTwoHalfOverlappingCirclesSeparate() {
        let buttons = [(x: 50.0, y: 50.0, size: 40.0), (x: 65.0, y: 50.0, size: 40.0)]
        let result = ButtonSeparation.separate(buttons, width: 200, height: 200)
        XCTAssertEqual(result.positions.count, 2)
        XCTAssertGreaterThan(distance(result.positions[0], result.positions[1]), 22)
        XCTAssertGreaterThan(result.movedCount, 0)
    }

    func testThreeStackedIdenticalCirclesSeparateDeterministically() {
        let buttons = [
            (x: 100.0, y: 100.0, size: 40.0),
            (x: 100.0, y: 100.0, size: 40.0),
            (x: 100.0, y: 100.0, size: 40.0),
        ]
        let first = ButtonSeparation.separate(buttons, width: 200, height: 200)
        let second = ButtonSeparation.separate(buttons, width: 200, height: 200)
        XCTAssertEqual(first.positions.count, second.positions.count)
        for (lhs, rhs) in zip(first.positions, second.positions) {
            XCTAssertEqual(lhs.x, rhs.x, accuracy: 1e-9)
            XCTAssertEqual(lhs.y, rhs.y, accuracy: 1e-9)
        }
        XCTAssertTrue(pairwiseNonOverlapping(positions: first.positions, sizes: buttons.map(\.size)))
    }

    func testClampingRespectsBounds() {
        let buttons = [(x: 5.0, y: 5.0, size: 40.0), (x: 195.0, y: 195.0, size: 40.0)]
        let result = ButtonSeparation.separate(buttons, width: 200, height: 200)
        for (index, point) in result.positions.enumerated() {
            let half = buttons[index].size * 0.5
            XCTAssertGreaterThanOrEqual(point.x, half)
            XCTAssertLessThanOrEqual(point.x, 200 - half)
            XCTAssertGreaterThanOrEqual(point.y, half)
            XCTAssertLessThanOrEqual(point.y, 200 - half)
        }
    }

    func testNonOverlappingInputUnchanged() {
        let buttons = [(x: 40.0, y: 40.0, size: 40.0), (x: 160.0, y: 160.0, size: 40.0)]
        let result = ButtonSeparation.separate(buttons, width: 200, height: 200)
        XCTAssertEqual(result.positions[0].x, 40, accuracy: 1e-6)
        XCTAssertEqual(result.positions[0].y, 40, accuracy: 1e-6)
        XCTAssertEqual(result.positions[1].x, 160, accuracy: 1e-6)
        XCTAssertEqual(result.positions[1].y, 160, accuracy: 1e-6)
        XCTAssertEqual(result.movedCount, 0)
    }

    private func distance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func pairwiseNonOverlapping(positions: [(x: Double, y: Double)], sizes: [Double]) -> Bool {
        for i in 0 ..< positions.count {
            for j in (i + 1) ..< positions.count {
                let required = (sizes[i] + sizes[j]) * 0.5
                if distance(positions[i], positions[j]) < required - 1e-6 {
                    return false
                }
            }
        }
        return true
    }
}

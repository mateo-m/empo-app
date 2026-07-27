import XCTest

@testable import GameProbe

/// Coordinate conventions in these tests: the D-pad is a 150x150 box,
/// so the center is (75, 75), the radius is 75, the dead zone ends at
/// 15 (0.2 * 75), and the slide-off release boundary is 105 (75 + 30).
/// +y points DOWN, matching view space: (75, 20) is on the UP arm.
/// Sample points are integer-valued wherever a test asserts a
/// threshold, so distances compute exactly and boundary assertions
/// can't drift on floating-point rounding.
final class DPadTouchReducerTests: XCTestCase {

    private let size = 150.0

    private func press(_ direction: DPadTouchReducer.Direction) -> DPadTouchReducer.Edge {
        DPadTouchReducer.Edge(direction: direction, pressed: true)
    }

    private func release(_ direction: DPadTouchReducer.Direction) -> DPadTouchReducer.Edge {
        DPadTouchReducer.Edge(direction: direction, pressed: false)
    }

    // MARK: Touch-down semantics

    /// THE regression this reducer exists to guard: the very first
    /// sample of a touch (the touch-down) must press its direction
    /// immediately. No movement, no lift, no second sample required.
    func testFirstSamplePressesImmediately() {
        var reducer = DPadTouchReducer()
        let edges = reducer.touchChanged(x: 75, y: 20, size: size)
        XCTAssertEqual(edges, [press(.up)])
        XCTAssertEqual(reducer.active, .up)
    }

    /// A tap is two separate emission batches — press edges on the
    /// down sample, release edges on the end — never a collapsed
    /// no-op. (Down+up in one engine batch is invisible to RGSS
    /// `Input.update`; a game like Pokemon Essentials needs the press
    /// to be observable on its own to turn the player in place.)
    func testTapEmitsPressAndReleaseAsSeparateBatches() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(x: 75, y: 130, size: size), [press(.down)])
        XCTAssertEqual(reducer.touchEnded(), [release(.down)])
        XCTAssertEqual(reducer.active, [])
    }

    // MARK: Wedge mapping

    func testCardinalAndDiagonalWedgeCenters() {
        let cases: [(x: Double, y: Double, expected: DPadTouchReducer.DirectionSet)] = [
            (135, 75, .right),
            (120, 120, [.right, .down]),
            (75, 135, .down),
            (30, 120, [.down, .left]),
            (15, 75, .left),
            (30, 30, [.left, .up]),
            (75, 15, .up),
            (120, 30, [.up, .right]),
        ]
        for c in cases {
            var reducer = DPadTouchReducer()
            _ = reducer.touchChanged(x: c.x, y: c.y, size: size)
            XCTAssertEqual(
                reducer.active, c.expected,
                "(\(c.x), \(c.y)) should map to \(c.expected)")
        }
    }

    /// The wedge dial in order; wedge i covers ((2i-1) * pi/8,
    /// (2i+1) * pi/8) around its center at i * pi/4.
    private static let wedgeDial: [DPadTouchReducer.DirectionSet] = [
        .right, [.right, .down], .down, [.down, .left],
        .left, [.left, .up], .up, [.up, .right],
    ]

    /// Angles WITHIN a wedge (a few ulp clear of both boundaries) map
    /// to exactly that wedge, against a literal expectation table —
    /// not values round-tripped through the same initializer.
    func testWedgeInteriorsMapExactly() {
        for (i, expected) in Self.wedgeDial.enumerated() {
            for offset in [-0.9, -0.5, 0, 0.5, 0.9] {
                let angle = (Double(i) * 2 + offset) * Double.pi / 8
                XCTAssertEqual(
                    DPadTouchReducer.DirectionSet(angle: angle), expected,
                    "angle \(Double(i) * 2 + offset) * pi/8 should map to wedge \(i)")
            }
        }
    }

    /// The internal normalization (`(angle + 2pi) mod 2pi`) can
    /// perturb an input by one ulp, so an angle EXACTLY on a pi/8
    /// boundary is not guaranteed a side. The invariant that IS
    /// shipped: every input at or within one ulp of a boundary
    /// resolves to one of the two wedges adjacent to that boundary —
    /// never a gap (`[]`), never a non-adjacent set. Verified for the
    /// positive dial and the equivalent negative (atan2-range) form
    /// of every boundary.
    func testWedgeBoundariesResolveToAnAdjacentWedge() {
        let s = Double.pi / 8
        for i in 0..<8 {
            // Boundary between wedge i and wedge i+1, at (2i+1)*pi/8.
            let boundary = Double(2 * i + 1) * s
            let adjacent = [Self.wedgeDial[i], Self.wedgeDial[(i + 1) % 8]]
            for angle in [
                boundary.nextDown, boundary, boundary.nextUp,
                (boundary - 2 * .pi).nextDown, boundary - 2 * .pi, (boundary - 2 * .pi).nextUp,
            ] {
                let set = DPadTouchReducer.DirectionSet(angle: angle)
                XCTAssertTrue(
                    adjacent.contains(set),
                    "angle \(angle) near boundary \(2 * i + 1) * pi/8 mapped to \(set), "
                        + "expected one of \(adjacent)")
            }
        }
    }

    /// atan2 output is negative for the whole upper half-plane; the
    /// normalization must land those in the same wedges as their
    /// positive equivalents.
    func testNegativeAnglesNormalize() {
        XCTAssertEqual(DPadTouchReducer.DirectionSet(angle: -Double.pi / 2), .up)
        XCTAssertEqual(DPadTouchReducer.DirectionSet(angle: -Double.pi / 4), [.up, .right])
        XCTAssertEqual(DPadTouchReducer.DirectionSet(angle: -Double.pi / 8), .right)
        XCTAssertEqual(DPadTouchReducer.DirectionSet(angle: Double.pi), .left)
    }

    /// The switch's `default` arm is the total-function fallback for
    /// inputs atan2 never produces: `truncatingRemainder` keeps the
    /// dividend's sign, so an angle below -2pi that is not an exact
    /// multiple of 2pi is still negative after the +2pi
    /// normalization and matches no wedge, as does NaN. Both must
    /// yield the EMPTY set — any direction here would be a phantom
    /// press from garbage input.
    func testOutOfRangeAndNonFiniteAnglesYieldNoDirections() {
        XCTAssertEqual(DPadTouchReducer.DirectionSet(angle: -9 * Double.pi / 4), [])
        XCTAssertEqual(DPadTouchReducer.DirectionSet(angle: .nan), [])
    }

    /// A non-finite sample (garbage coordinates) fails every range
    /// comparison and falls through to the empty wedge set: the
    /// reducer must RELEASE everything rather than stick or press
    /// opposing directions.
    func testNaNSampleReleasesEverything() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(x: 75, y: 20, size: size), [press(.up)])
        XCTAssertEqual(
            reducer.touchChanged(x: .nan, y: .nan, size: size),
            [release(.up)])
        XCTAssertEqual(reducer.active, [])
    }

    // MARK: Geometry scaling

    /// Every threshold derives from `size` — a reducer that hardcodes
    /// the 150-point geometry the rest of this file uses would pass
    /// every other test. At size 300 the dead zone ends at 30, the
    /// radius is 150, and slide-off releases past 180.
    func testGeometryScalesWithSize() {
        var reducer = DPadTouchReducer()
        // Distance 20 from the (150, 150) center: pressable under the
        // default 150-point geometry, dead-zoned at size 300.
        XCTAssertEqual(reducer.touchChanged(x: 150, y: 130, size: 300), [])
        XCTAssertEqual(reducer.touchChanged(x: 150, y: 30, size: 300), [press(.up)])
        // Distance exactly 180 = radius + margin: still inside.
        XCTAssertEqual(reducer.touchChanged(x: 150, y: -30, size: 300), [])
        XCTAssertEqual(reducer.active, .up)
        XCTAssertEqual(reducer.touchChanged(x: 150, y: -31, size: 300), [release(.up)])
    }

    /// `size` is read per sample, not cached from the first one: an
    /// edit-dialog resize mid-session must move the center and
    /// thresholds immediately. The same physical point is an UP press
    /// under a 200-point pad (center 100) and a RIGHT press under an
    /// 80-point pad (center 40).
    func testMidTouchResizeUsesTheNewGeometry() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(x: 100, y: 40, size: 200), [press(.up)])
        XCTAssertEqual(
            reducer.touchChanged(x: 100, y: 40, size: 80),
            [release(.up), press(.right)])
    }

    // MARK: Dead zone

    func testDeadZoneSwallowsCenterTouches() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(x: 75, y: 75, size: size), [])
        // Distance 10, inside the 15-point dead zone.
        XCTAssertEqual(reducer.touchChanged(x: 75, y: 65, size: size), [])
        XCTAssertEqual(reducer.active, [])
    }

    /// The dead-zone comparison is strict (`distance < deadZone`), so
    /// a touch at EXACTLY the dead-zone radius engages its wedge.
    func testDeadZoneBoundaryEngages() {
        var reducer = DPadTouchReducer()
        // (75, 60): distance exactly 15 = 0.2 * 75.
        XCTAssertEqual(reducer.touchChanged(x: 75, y: 60, size: size), [press(.up)])
    }

    func testRetreatIntoDeadZoneReleasesEverything() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(x: 120, y: 30, size: size)
        XCTAssertEqual(reducer.active, [.up, .right])
        XCTAssertEqual(
            reducer.touchChanged(x: 75, y: 75, size: size),
            [release(.up), release(.right)])
        XCTAssertEqual(reducer.active, [])
    }

    // MARK: Slide-off

    func testSlideOffReleasesOnceAndReengages() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(x: 75, y: 20, size: size), [press(.up)])

        // (75, -30): distance exactly 105 = radius + margin. The
        // comparison is strict (`>`), so the boundary itself is still
        // inside — the direction must stay held.
        XCTAssertEqual(reducer.touchChanged(x: 75, y: -30, size: size), [])
        XCTAssertEqual(reducer.active, .up)

        // One point past the boundary: release everything.
        XCTAssertEqual(reducer.touchChanged(x: 75, y: -31, size: size), [release(.up)])
        XCTAssertEqual(reducer.active, [])

        // Parked beyond the edge: the release batch must NOT repeat.
        XCTAssertEqual(reducer.touchChanged(x: 75, y: -40, size: size), [])
        XCTAssertEqual(reducer.touchChanged(x: 80, y: -35, size: size), [])

        // Sliding back inside re-presses without a new touch.
        XCTAssertEqual(reducer.touchChanged(x: 75, y: 20, size: size), [press(.up)])
    }

    /// Ending a touch while slid off (already released) is silent,
    /// and the reducer is immediately reusable for the next touch.
    func testTouchEndedAfterSlideOffIsSilentAndReducerIsReusable() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(x: 75, y: 20, size: size)
        _ = reducer.touchChanged(x: 75, y: -31, size: size)
        XCTAssertEqual(reducer.touchEnded(), [])
        XCTAssertEqual(reducer.touchChanged(x: 15, y: 75, size: size), [press(.left)])
    }

    // MARK: Edge diffing

    func testSteadyHoldEmitsNothing() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(x: 120, y: 120, size: size), [press(.down), press(.right)])
        for _ in 0..<5 {
            XCTAssertEqual(reducer.touchChanged(x: 120, y: 120, size: size), [])
        }
        // Wobble within the same wedge is also silent.
        XCTAssertEqual(reducer.touchChanged(x: 118, y: 121, size: size), [])
    }

    /// Rolling NE -> E -> SE must keep RIGHT held through the whole
    /// roll: only the vertical component may change. A release of the
    /// shared direction anywhere in the sequence is the stutter bug.
    func testDiagonalRollNeverReleasesTheSharedDirection() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(x: 120, y: 30, size: size), [press(.up), press(.right)])
        XCTAssertEqual(reducer.touchChanged(x: 135, y: 75, size: size), [release(.up)])
        XCTAssertEqual(reducer.touchChanged(x: 120, y: 120, size: size), [press(.down)])
        XCTAssertEqual(reducer.active, [.down, .right])
    }

    /// A jump between opposite wedges emits the release BEFORE the
    /// press, in one batch, so a caller injecting in order can never
    /// leave the engine holding left+right simultaneously.
    func testOppositeJumpOrdersReleaseBeforePress() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(x: 15, y: 75, size: size)
        XCTAssertEqual(
            reducer.touchChanged(x: 135, y: 75, size: size),
            [release(.left), press(.right)])
    }

    func testDiagonalToOppositeDiagonalOrdersAllReleasesFirst() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(x: 120, y: 30, size: size)
        XCTAssertEqual(
            reducer.touchChanged(x: 30, y: 120, size: size),
            [release(.up), release(.right), press(.down), press(.left)])
    }

    func testTouchEndedReleasesEveryHeldDirection() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(x: 120, y: 30, size: size)
        XCTAssertEqual(reducer.touchEnded(), [release(.up), release(.right)])
        XCTAssertEqual(reducer.active, [])
        // A second end with nothing held is silent, not a re-release.
        XCTAssertEqual(reducer.touchEnded(), [])
    }

    // MARK: Parameter plumbing

    /// Custom thresholds must actually be used — a reducer that
    /// hardcodes the defaults would pass every other test.
    func testCustomDeadZoneRatioIsRespected() {
        var reducer = DPadTouchReducer()
        // Distance 45 from center: outside the default dead zone (15),
        // inside a 0.7 * 75 = 52.5 one.
        XCTAssertEqual(
            reducer.touchChanged(x: 75, y: 30, size: size, deadZoneRatio: 0.7), [])
        XCTAssertEqual(
            reducer.touchChanged(x: 75, y: 30, size: size), [press(.up)])
    }

    func testCustomSlideOffMarginIsRespected() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(x: 75, y: 20, size: size)
        // Distance 76: within the default margin (105), outside a
        // zero-margin boundary (75).
        XCTAssertEqual(
            reducer.touchChanged(x: 75, y: -1, size: size, slideOffMargin: 0),
            [release(.up)])
    }

    // MARK: Whole-dial invariants

    /// Sweep a full circle twice at valid radius and re-derive the
    /// held set purely from the emitted edges. Catches every protocol
    /// violation that would stick or drop a key at the engine:
    /// double-press, double-release, a release of something not held,
    /// presses ordered before releases, an empty or over-full active
    /// set, and opposite directions held together.
    func testFullSweepEdgeStreamStaysConsistent() {
        var reducer = DPadTouchReducer()
        var held = Set<DPadTouchReducer.Direction>()

        for step in 0..<1440 {
            let angle = Double(step) / 720.0 * 2 * .pi
            let x = 75 + 60 * cos(angle)
            let y = 75 + 60 * sin(angle)
            let edges = reducer.touchChanged(x: x, y: y, size: size)

            var sawPress = false
            for edge in edges {
                if edge.pressed {
                    sawPress = true
                    XCTAssertTrue(
                        held.insert(edge.direction).inserted,
                        "step \(step): pressed \(edge.direction) while already held")
                } else {
                    XCTAssertFalse(
                        sawPress, "step \(step): release ordered after a press")
                    XCTAssertNotNil(
                        held.remove(edge.direction),
                        "step \(step): released \(edge.direction) without holding it")
                }
            }

            XCTAssertEqual(
                held, Set(reducer.active.directions),
                "step \(step): edge stream disagrees with active set")
            XCTAssertTrue(
                (1...2).contains(held.count),
                "step \(step): \(held.count) directions held at valid radius")
            XCTAssertFalse(
                held.isSuperset(of: [.up, .down]), "step \(step): up+down held together")
            XCTAssertFalse(
                held.isSuperset(of: [.left, .right]), "step \(step): left+right held together")
        }

        for edge in reducer.touchEnded() {
            XCTAssertFalse(edge.pressed)
            XCTAssertNotNil(held.remove(edge.direction))
        }
        XCTAssertTrue(held.isEmpty, "touchEnded left directions stuck")
    }

    // MARK: DirectionSet

    /// Emission order is fixed (up, down, left, right) regardless of
    /// construction order, so edge arrays are deterministic. Pinned
    /// for the full set too: the reducer never produces opposing
    /// pairs, but `DirectionSet` is public API.
    func testDirectionsIterationOrderIsStable() {
        XCTAssertEqual(
            DPadTouchReducer.DirectionSet([.right, .up]).directions, [.up, .right])
        XCTAssertEqual(
            DPadTouchReducer.DirectionSet([.left, .down]).directions, [.down, .left])
        XCTAssertEqual(DPadTouchReducer.DirectionSet().directions, [])
        XCTAssertEqual(
            DPadTouchReducer.DirectionSet([.up, .down, .left, .right]).directions,
            [.up, .down, .left, .right])
    }
}

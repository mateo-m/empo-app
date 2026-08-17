import XCTest

@testable import GameProbe

final class MovementStickTuningTests: XCTestCase {

    func testConstantsArePinned() {
        XCTAssertEqual(MovementStickTuning.deadZoneRatio, 0.2)
        XCTAssertEqual(MovementStickTuning.cardinalOnlyRadiusRatio, 0.3)
        XCTAssertEqual(MovementStickTuning.slideOffMarginRatio, 0.6)
        XCTAssertEqual(MovementStickTuning.slideOffMargin(size: 140), 42)
        XCTAssertEqual(MovementStickTuning.nubRatio, 0.42)
    }

    func testThumbOffsetTracksTheFingerInsideTheTravelRadius() {
        // size 100: radius 50, nub 42, travel 29. A touch 20pt right
        // of center stays unclamped.
        let offset = MovementStickTuning.thumbOffset(x: 70, y: 50, size: 100)
        XCTAssertEqual(offset.dx, 20, accuracy: 0.001)
        XCTAssertEqual(offset.dy, 0, accuracy: 0.001)
    }

    func testThumbOffsetClampsAtTheTravelRadius() {
        // A touch far outside the base pins the nub at travel = 29.
        let offset = MovementStickTuning.thumbOffset(x: 300, y: 50, size: 100)
        XCTAssertEqual(offset.dx, 29, accuracy: 0.001)
        XCTAssertEqual(offset.dy, 0, accuracy: 0.001)
    }

    func testThumbOffsetAtDeadCenterStaysPut() {
        let offset = MovementStickTuning.thumbOffset(x: 50, y: 50, size: 100)
        XCTAssertEqual(offset.dx, 0, accuracy: 0.001)
        XCTAssertEqual(offset.dy, 0, accuracy: 0.001)
    }

    /// The style -> thresholds mapping the host samples with. The
    /// d-pad takes the reducer defaults. Only the stick differs.
    func testTuningPerStyle() {
        let dpad = MovementStyle.dpad.tuning(size: 140)
        XCTAssertEqual(dpad.deadZoneRatio, DPadTouchReducer.defaultDeadZoneRatio)
        XCTAssertEqual(dpad.cardinalOnlyRadiusRatio, DPadTouchReducer.defaultCardinalOnlyRadiusRatio)
        XCTAssertEqual(dpad.slideOffMargin, DPadTouchReducer.defaultSlideOffMargin)
        // The d-pad margin is fixed. The stick's scales with the size.
        XCTAssertEqual(MovementStyle.dpad.tuning(size: 400).slideOffMargin, dpad.slideOffMargin)

        let stick = MovementStyle.stick.tuning(size: 140)
        XCTAssertEqual(stick.deadZoneRatio, MovementStickTuning.deadZoneRatio)
        XCTAssertEqual(stick.cardinalOnlyRadiusRatio, 0.3)
        XCTAssertEqual(stick.slideOffMargin, 42)
    }

    /// Sampling with a tuning value must land exactly where the same
    /// thresholds do one by one. The host uses the short form.
    func testTuningSampleMatchesExplicitThresholds() {
        let size = 140.0
        var byTuning = DPadTouchReducer()
        var byThreshold = DPadTouchReducer()
        let offset = 0.4 * size / 2 * (0.5.squareRoot())

        let edges = byTuning.touchChanged(
            touch: 1, x: size / 2 + offset, y: size / 2 + offset, size: size,
            tuning: MovementStyle.stick.tuning(size: size))
        XCTAssertEqual(edges, stickEdges(&byThreshold, x: size / 2 + offset, y: size / 2 + offset, size: size))
        XCTAssertEqual(byTuning.active, byThreshold.active)
        XCTAssertEqual(byTuning.active, [.down, .right])
    }

    private func stickEdges(
        _ reducer: inout DPadTouchReducer, x: Double, y: Double, size: Double
    ) -> [DPadTouchReducer.Edge] {
        reducer.touchChanged(
            touch: 1, x: x, y: y, size: size,
            deadZoneRatio: MovementStickTuning.deadZoneRatio,
            cardinalOnlyRadiusRatio: MovementStickTuning.cardinalOnlyRadiusRatio,
            slideOffMargin: MovementStickTuning.slideOffMargin(size: size)
        )
    }

    func testDiagonalUnlocksEarlierThanDPad() {
        // At 0.4 x radius, 45 degrees: the stick's 0.3 cardinal ring
        // is behind us (diagonal allowed). The d-pad's 0.5 ring would
        // still force a cardinal.
        let size = 140.0
        let offset = 0.4 * size / 2 * (0.5.squareRoot())

        var stick = DPadTouchReducer()
        _ = stickEdges(&stick, x: size / 2 + offset, y: size / 2 + offset, size: size)
        XCTAssertEqual(stick.active, [.down, .right])

        var dpad = DPadTouchReducer()
        _ = dpad.touchChanged(touch: 1, x: size / 2 + offset, y: size / 2 + offset, size: size)
        XCTAssertEqual(dpad.active.directions.count, 1)
    }

    func testCardinalOnlyInsideStickRing() {
        // 25% of the radius, slightly angled: still cardinal.
        let size = 140.0
        var stick = DPadTouchReducer()
        _ = stickEdges(&stick, x: size / 2 + 0.25 * size / 2, y: size / 2 + 6, size: size)
        XCTAssertEqual(stick.active, .right)
    }

    func testProportionalSlideOffReleasesAndReengages() {
        let size = 140.0
        var stick = DPadTouchReducer()
        _ = stickEdges(&stick, x: size, y: size / 2, size: size)
        XCTAssertEqual(stick.active, .right)
        // Past radius x 1.6: everything releases.
        _ = stickEdges(&stick, x: size / 2 + size * 0.85, y: size / 2, size: size)
        XCTAssertEqual(stick.active, [])
        // Back inside: re-presses.
        _ = stickEdges(&stick, x: size, y: size / 2, size: size)
        XCTAssertEqual(stick.active, .right)
    }
}

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
        let edges = reducer.touchChanged(touch: 1, x: 75, y: 20, size: size)
        XCTAssertEqual(edges, [press(.up)])
        XCTAssertEqual(reducer.active, .up)
    }

    /// A tap is two separate emission batches, press edges on the
    /// down sample, release edges on the end, never a collapsed
    /// no-op. (Down+up in one engine batch is invisible to RGSS
    /// `Input.update`. A game like Pokemon Essentials needs the press
    /// to be observable on its own to turn the player in place.)
    func testTapEmitsPressAndReleaseAsSeparateBatches() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: 130, size: size), [press(.down)])
        XCTAssertEqual(reducer.touchEnded(touch: 1), [release(.down)])
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
            _ = reducer.touchChanged(touch: 1, x: c.x, y: c.y, size: size)
            XCTAssertEqual(
                reducer.active, c.expected,
                "(\(c.x), \(c.y)) should map to \(c.expected)")
        }
    }

    /// The wedge dial in order. Wedge i covers ((2i-1) * pi/8,
    /// (2i+1) * pi/8) around its center at i * pi/4.
    private static let wedgeDial: [DPadTouchReducer.DirectionSet] = [
        .right, [.right, .down], .down, [.down, .left],
        .left, [.left, .up], .up, [.up, .right],
    ]

    /// Angles WITHIN a wedge (a few ulp clear of both boundaries) map
    /// to exactly that wedge, against a literal expectation table.
    /// Not values round-tripped through the same initializer.
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
    /// resolves to one of the two wedges adjacent to that boundary.
    /// Never a gap (`[]`), never a non-adjacent set. Verified for the
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

    /// The four cardinal sectors of `init(cardinalAngle:)`, pinned
    /// against a literal table for interior angles (well clear of the
    /// pi/4 boundaries).
    func testCardinalAngleInteriorsMapExactly() {
        let dial: [DPadTouchReducer.DirectionSet] = [.right, .down, .left, .up]
        for (i, expected) in dial.enumerated() {
            for offset in [-0.9, -0.5, 0, 0.5, 0.9] {
                let angle = Double(i) * .pi / 2 + offset * .pi / 4
                XCTAssertEqual(
                    DPadTouchReducer.DirectionSet(cardinalAngle: angle), expected,
                    "cardinal angle \(angle) should map to sector \(i)")
            }
        }
    }

    /// Same adjacency contract at the pi/4 boundaries as the 8-wedge
    /// map: normalization can perturb by one ulp, so an exact
    /// boundary angle resolves to one of the two neighboring
    /// cardinals. Never a diagonal, never empty.
    func testCardinalAngleBoundariesResolveToAnAdjacentCardinal() {
        let dial: [DPadTouchReducer.DirectionSet] = [.right, .down, .left, .up]
        let s = Double.pi / 4
        for i in 0..<4 {
            let boundary = Double(2 * i + 1) * s
            let adjacent = [dial[i], dial[(i + 1) % 4]]
            for angle in [
                boundary.nextDown, boundary, boundary.nextUp,
                (boundary - 2 * .pi).nextDown, boundary - 2 * .pi, (boundary - 2 * .pi).nextUp,
            ] {
                let set = DPadTouchReducer.DirectionSet(cardinalAngle: angle)
                XCTAssertTrue(
                    adjacent.contains(set),
                    "cardinal angle \(angle) near boundary \(2 * i + 1) * pi/4 mapped to \(set)")
            }
        }
    }

    /// Total-function fallback, same contract as `init(angle:)`.
    func testCardinalAngleGarbageInputYieldsNoDirections() {
        XCTAssertEqual(DPadTouchReducer.DirectionSet(cardinalAngle: -9 * Double.pi / 4), [])
        XCTAssertEqual(DPadTouchReducer.DirectionSet(cardinalAngle: .nan), [])
    }

    /// atan2 output is negative for the whole upper half-plane. The
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
    /// yield the EMPTY set. Any direction here would be a phantom
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
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: 20, size: size), [press(.up)])
        XCTAssertEqual(
            reducer.touchChanged(touch: 1, x: .nan, y: .nan, size: size),
            [release(.up)])
        XCTAssertEqual(reducer.active, [])
    }

    // MARK: Geometry scaling

    /// Every threshold derives from `size`. A reducer that hardcodes
    /// the 150-point geometry the rest of this file uses would pass
    /// every other test. At size 300 the dead zone ends at 30, the
    /// radius is 150, and slide-off releases past 180.
    func testGeometryScalesWithSize() {
        var reducer = DPadTouchReducer()
        // Distance 20 from the (150, 150) center: pressable under the
        // default 150-point geometry, dead-zoned at size 300.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 150, y: 130, size: 300), [])
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 150, y: 30, size: 300), [press(.up)])
        // Distance exactly 180 = radius + margin: still inside.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 150, y: -30, size: 300), [])
        XCTAssertEqual(reducer.active, .up)
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 150, y: -31, size: 300), [release(.up)])
    }

    /// `size` is read per sample, not cached from the first one: an
    /// edit-dialog resize mid-session must move the center and
    /// thresholds immediately. The same physical point is an UP press
    /// under a 200-point pad (center 100) and a RIGHT press under an
    /// 80-point pad (center 40).
    func testMidTouchResizeUsesTheNewGeometry() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 100, y: 40, size: 200), [press(.up)])
        XCTAssertEqual(
            reducer.touchChanged(touch: 1, x: 100, y: 40, size: 80),
            [release(.up), press(.right)])
    }

    // MARK: Dead zone

    func testDeadZoneSwallowsCenterTouches() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: 75, size: size), [])
        // Distance 10, inside the 15-point dead zone.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: 65, size: size), [])
        XCTAssertEqual(reducer.active, [])
    }

    /// The dead-zone comparison is strict (`distance < deadZone`), so
    /// a touch at EXACTLY the dead-zone radius engages its wedge.
    func testDeadZoneBoundaryEngages() {
        var reducer = DPadTouchReducer()
        // (75, 60): distance exactly 15 = 0.2 * 75.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: 60, size: size), [press(.up)])
    }

    func testRetreatIntoDeadZoneReleasesEverything() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 120, y: 30, size: size)
        XCTAssertEqual(reducer.active, [.up, .right])
        XCTAssertEqual(
            reducer.touchChanged(touch: 1, x: 75, y: 75, size: size),
            [release(.up), release(.right)])
        XCTAssertEqual(reducer.active, [])
    }

    // MARK: Cardinal-only inner ring

    /// Between the dead zone (15) and half the radius (37.5), a
    /// touch resolves to the nearest MAIN direction even at an angle
    /// the 8-wedge map would call diagonal. Both points below sit at
    /// distance 22.36, at angles deep inside the up+right diagonal
    /// wedge. The ring picks the nearer axis instead.
    func testInnerRingResolvesToNearestCardinal() {
        var reducer = DPadTouchReducer()
        // 26.6 degrees above the +x axis: right of the 45-degree line.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 95, y: 65, size: size), [press(.right)])
        XCTAssertEqual(reducer.active, .right)

        var reducer2 = DPadTouchReducer()
        // 63.4 degrees above the +x axis: up side of the 45-degree line.
        XCTAssertEqual(reducer2.touchChanged(touch: 1, x: 85, y: 55, size: size), [press(.up)])
    }

    /// The ring comparison is strict (`distance < ratio * radius`):
    /// AT the boundary the full 8-wedge map applies. 3-4-5 triangle
    /// at size 300 (ring radius 75): (195, 90) is at distance
    /// exactly 75 -> diagonal allowed. (192, 94) is at 70 -> inside
    /// the ring, cardinal only.
    func testInnerRingBoundaryKeepsFullWedges() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(
            reducer.touchChanged(touch: 1, x: 195, y: 90, size: 300),
            [press(.up), press(.right)])

        var inner = DPadTouchReducer()
        XCTAssertEqual(inner.touchChanged(touch: 1, x: 192, y: 94, size: 300), [press(.up)])
    }

    /// Drifting inward across the ring at a diagonal angle drops
    /// ONLY the off-axis component. The direction the cardinal map
    /// keeps must never release and re-press (no stutter at the ring
    /// boundary).
    func testDriftIntoRingDropsOnlyTheOffAxisComponent() {
        var reducer = DPadTouchReducer()
        // Distance 49.2, angle 26.6 degrees into the up+right wedge.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 119, y: 53, size: size), [press(.up), press(.right)])
        // Same angle, distance 22.4: inside the ring -> right only.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 95, y: 65, size: size), [release(.up)])
        XCTAssertEqual(reducer.active, .right)
    }

    /// The ratio must be used: 0 disables the ring entirely
    /// (diagonals available right outside the dead zone), 1 extends
    /// it to the rim (diagonals unreachable).
    func testCustomCardinalOnlyRadiusRatioIsRespected() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(
            reducer.touchChanged(touch: 1, x: 95, y: 65, size: size, cardinalOnlyRadiusRatio: 0),
            [press(.up), press(.right)])

        var wide = DPadTouchReducer()
        XCTAssertEqual(
            wide.touchChanged(touch: 1, x: 119, y: 53, size: size, cardinalOnlyRadiusRatio: 1),
            [press(.right)])
    }

    /// Sweep a full circle twice INSIDE the ring: exactly one
    /// cardinal is held at every step, transitions are
    /// release-then-press, and the edge stream stays consistent with
    /// the active set.
    func testInnerRingSweepHoldsExactlyOneDirection() {
        var reducer = DPadTouchReducer()
        var held = Set<DPadTouchReducer.Direction>()

        for step in 0..<1440 {
            let angle = Double(step) / 720.0 * 2 * .pi
            let x = 75 + 25 * cos(angle)
            let y = 75 + 25 * sin(angle)
            let edges = reducer.touchChanged(touch: 1, x: x, y: y, size: size)

            var sawPress = false
            for edge in edges {
                if edge.pressed {
                    sawPress = true
                    XCTAssertTrue(held.insert(edge.direction).inserted, "step \(step)")
                } else {
                    XCTAssertFalse(sawPress, "step \(step): release ordered after a press")
                    XCTAssertNotNil(held.remove(edge.direction), "step \(step)")
                }
            }

            XCTAssertEqual(held, Set(reducer.active.directions), "step \(step)")
            XCTAssertEqual(held.count, 1, "step \(step): ring must hold exactly one cardinal")
        }
    }

    // MARK: Slide-off

    func testSlideOffReleasesOnceAndReengages() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: 20, size: size), [press(.up)])

        // (75, -30): distance exactly 105 = radius + margin. The
        // comparison is strict (`>`), so the boundary itself is still
        // inside. The direction must stay held.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: -30, size: size), [])
        XCTAssertEqual(reducer.active, .up)

        // One point past the boundary: release everything.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: -31, size: size), [release(.up)])
        XCTAssertEqual(reducer.active, [])

        // Parked beyond the edge: the release batch must NOT repeat.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: -40, size: size), [])
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 80, y: -35, size: size), [])

        // Sliding back inside re-presses without a new touch.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: 20, size: size), [press(.up)])
    }

    /// Ending a touch while slid off (already released) is silent,
    /// and the reducer is immediately reusable for the next touch.
    func testTouchEndedAfterSlideOffIsSilentAndReducerIsReusable() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 75, y: 20, size: size)
        _ = reducer.touchChanged(touch: 1, x: 75, y: -31, size: size)
        XCTAssertEqual(reducer.touchEnded(touch: 1), [])
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 15, y: 75, size: size), [press(.left)])
    }

    // MARK: Edge diffing

    func testSteadyHoldEmitsNothing() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 120, y: 120, size: size), [press(.down), press(.right)])
        for _ in 0..<5 {
            XCTAssertEqual(reducer.touchChanged(touch: 1, x: 120, y: 120, size: size), [])
        }
        // Wobble within the same wedge is also silent.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 118, y: 121, size: size), [])
    }

    /// Rolling NE -> E -> SE must keep RIGHT held through the whole
    /// roll: only the vertical component may change. A release of the
    /// shared direction anywhere in the sequence is the stutter bug.
    func testDiagonalRollNeverReleasesTheSharedDirection() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 120, y: 30, size: size), [press(.up), press(.right)])
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 135, y: 75, size: size), [release(.up)])
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 120, y: 120, size: size), [press(.down)])
        XCTAssertEqual(reducer.active, [.down, .right])
    }

    /// A jump between opposite wedges emits the release BEFORE the
    /// press, in one batch, so a caller injecting in order can never
    /// leave the engine holding left+right simultaneously.
    func testOppositeJumpOrdersReleaseBeforePress() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 15, y: 75, size: size)
        XCTAssertEqual(
            reducer.touchChanged(touch: 1, x: 135, y: 75, size: size),
            [release(.left), press(.right)])
    }

    func testDiagonalToOppositeDiagonalOrdersAllReleasesFirst() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 120, y: 30, size: size)
        XCTAssertEqual(
            reducer.touchChanged(touch: 1, x: 30, y: 120, size: size),
            [release(.up), release(.right), press(.down), press(.left)])
    }

    func testTouchEndedReleasesEveryHeldDirection() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 120, y: 30, size: size)
        XCTAssertEqual(reducer.touchEnded(touch: 1), [release(.up), release(.right)])
        XCTAssertEqual(reducer.active, [])
        // A second end for the same finger is silent, not a
        // re-release: touchesEnded and touchesCancelled can both
        // arrive for one touch.
        XCTAssertEqual(reducer.touchEnded(touch: 1), [])
        XCTAssertEqual(reducer.releaseAll(), [])
    }

    // MARK: Multi-touch

    /// THE behaviour this reducer gained for two thumbs: hold the
    /// RIGHT arm, land a second finger on the DOWN arm, and the pad
    /// holds both. Like a physical D-pad. Lifting the first finger
    /// keeps DOWN held, so the player never has to lift the second
    /// finger and press it again.
    func testSecondFingerAddsItsDirectionAndSurvivesTheFirstLift() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 135, y: 75, size: size), [press(.right)])
        XCTAssertEqual(reducer.touchChanged(touch: 2, x: 75, y: 135, size: size), [press(.down)])
        XCTAssertEqual(reducer.active, [.down, .right])

        // The first finger lifts: only RIGHT goes, and DOWN is NOT
        // released and re-pressed on the way (that stutter would
        // cost the player a step).
        XCTAssertEqual(reducer.touchEnded(touch: 1), [release(.right)])
        XCTAssertEqual(reducer.active, .down)

        XCTAssertEqual(reducer.touchEnded(touch: 2), [release(.down)])
        XCTAssertEqual(reducer.active, [])
    }

    /// Opposite arms under two fingers hold both keys, exactly as a
    /// keyboard does with both arrow keys down. The reducer must not
    /// invent a winner. The game decides.
    func testOppositeArmsUnderTwoFingersHoldBoth() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 15, y: 75, size: size)
        XCTAssertEqual(reducer.touchChanged(touch: 2, x: 135, y: 75, size: size), [press(.right)])
        XCTAssertEqual(reducer.active, [.left, .right])
    }

    /// Two fingers on the SAME arm: the direction presses once, and
    /// it stays held until the second finger lifts too.
    func testTwoFingersOnOneArmPressOnceAndHoldToTheLast() {
        var reducer = DPadTouchReducer()
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: 20, size: size), [press(.up)])
        XCTAssertEqual(reducer.touchChanged(touch: 2, x: 80, y: 25, size: size), [])
        XCTAssertEqual(reducer.touchEnded(touch: 1), [])
        XCTAssertEqual(reducer.active, .up)
        XCTAssertEqual(reducer.touchEnded(touch: 2), [release(.up)])
    }

    /// Each finger keeps its own geometry state: one sliding off the
    /// pad releases only what it held.
    func testOneFingerSlidingOffLeavesTheOtherHeld() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 75, y: 20, size: size)
        _ = reducer.touchChanged(touch: 2, x: 135, y: 75, size: size)
        XCTAssertEqual(reducer.active, [.up, .right])
        // Finger 1 past radius + margin: UP goes, RIGHT stays.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: -31, size: size), [release(.up)])
        XCTAssertEqual(reducer.active, .right)
        // It slides back in and re-presses without a new touch.
        XCTAssertEqual(reducer.touchChanged(touch: 1, x: 75, y: 20, size: size), [press(.up)])
    }

    /// Moving one finger must not disturb the other: a roll from the
    /// UP arm to the LEFT arm swaps only that finger's direction.
    func testMovingOneFingerLeavesTheOtherDirectionHeld() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 135, y: 75, size: size)
        _ = reducer.touchChanged(touch: 2, x: 75, y: 20, size: size)
        XCTAssertEqual(
            reducer.touchChanged(touch: 2, x: 75, y: 130, size: size),
            [release(.up), press(.down)])
        XCTAssertEqual(reducer.active, [.down, .right])
    }

    /// Host-driven cancellation (edit mode, or the control torn out
    /// mid-press) drops every finger at once and leaves nothing held
    /// at the engine.
    func testReleaseAllDropsEveryFinger() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 135, y: 75, size: size)
        _ = reducer.touchChanged(touch: 2, x: 75, y: 135, size: size)
        XCTAssertEqual(reducer.releaseAll(), [release(.down), release(.right)])
        XCTAssertEqual(reducer.active, [])
        XCTAssertNil(reducer.leadTouchPoint)
        // The dropped fingers' own late ends must not fire again.
        XCTAssertEqual(reducer.touchEnded(touch: 1), [])
        XCTAssertEqual(reducer.touchEnded(touch: 2), [])
    }

    /// The joystick nub follows the OLDEST live finger, so a second
    /// thumb never yanks it away. It hands over when that finger
    /// lifts, and clears when the pad is idle.
    func testLeadTouchPointFollowsTheOldestFinger() {
        var reducer = DPadTouchReducer()
        XCTAssertNil(reducer.leadTouchPoint)

        _ = reducer.touchChanged(touch: 1, x: 135, y: 75, size: size)
        _ = reducer.touchChanged(touch: 2, x: 75, y: 135, size: size)
        XCTAssertEqual(reducer.leadTouchPoint?.x, 135)
        XCTAssertEqual(reducer.leadTouchPoint?.y, 75)

        // The lead finger moves: the point tracks it.
        _ = reducer.touchChanged(touch: 1, x: 130, y: 80, size: size)
        XCTAssertEqual(reducer.leadTouchPoint?.x, 130)
        XCTAssertEqual(reducer.leadTouchPoint?.y, 80)

        // It lifts: the remaining finger leads.
        _ = reducer.touchEnded(touch: 1)
        XCTAssertEqual(reducer.leadTouchPoint?.x, 75)
        XCTAssertEqual(reducer.leadTouchPoint?.y, 135)

        _ = reducer.touchEnded(touch: 2)
        XCTAssertNil(reducer.leadTouchPoint)
    }

    /// An unknown finger is silent. A late end after cancellation
    /// must not release what a live finger holds.
    func testUnknownTouchEndingChangesNothing() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 135, y: 75, size: size)
        XCTAssertEqual(reducer.touchEnded(touch: 99), [])
        XCTAssertEqual(reducer.active, .right)
    }

    // MARK: Parameter plumbing

    /// Custom thresholds must be used. A reducer that
    /// hardcodes the defaults would pass every other test.
    func testCustomDeadZoneRatioIsRespected() {
        var reducer = DPadTouchReducer()
        // Distance 45 from center: outside the default dead zone (15),
        // inside a 0.7 * 75 = 52.5 one.
        XCTAssertEqual(
            reducer.touchChanged(touch: 1, x: 75, y: 30, size: size, deadZoneRatio: 0.7), [])
        XCTAssertEqual(
            reducer.touchChanged(touch: 1, x: 75, y: 30, size: size), [press(.up)])
    }

    func testCustomSlideOffMarginIsRespected() {
        var reducer = DPadTouchReducer()
        _ = reducer.touchChanged(touch: 1, x: 75, y: 20, size: size)
        // Distance 76: within the default margin (105), outside a
        // zero-margin boundary (75).
        XCTAssertEqual(
            reducer.touchChanged(touch: 1, x: 75, y: -1, size: size, slideOffMargin: 0),
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
            let edges = reducer.touchChanged(touch: 1, x: x, y: y, size: size)

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

        for edge in reducer.touchEnded(touch: 1) {
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

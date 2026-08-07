import XCTest

@testable import GameProbe

final class OrientationDerivationTests: XCTestCase {

    private let metrics = TouchZoneMetrics.reference

    private let defaultDpad = TouchSectionCompletion.DefaultDpadSpec(
        portraitX: 0.13,
        portraitY: 0.72,
        landscapeX: 0.10,
        landscapeY: 0.65,
        size: 140
    )

    // MARK: - Derivation transform

    func testActionButtonsDeriveWithButtons() {
        var portrait = samplePortraitLayout()
        portrait.actionButtons = [
            ActionButtonSpec(action: "$toggleFastForward", x: 0.9, y: 0.1, size: 56, opacity: 0.8)
        ]
        let landscape = OrientationDerivation.derive(
            from: portrait,
            sourceIsLandscape: false,
            metrics: metrics,
            defaultDpad: nil
        )

        XCTAssertEqual(landscape.actionButtons?.count, 1)
        let derived = landscape.actionButtons?.first
        XCTAssertEqual(derived?.action, "$toggleFastForward")
        XCTAssertEqual(derived?.size, 56)
        XCTAssertEqual(derived?.opacity, 0.8)
        XCTAssertTrue((0.0...1.0).contains(derived?.x ?? -1))
        XCTAssertTrue((0.0...1.0).contains(derived?.y ?? -1))
        // Plain buttons still derive alongside.
        XCTAssertEqual(landscape.buttons?.count, portrait.buttons?.count)
    }

    func testActionButtonPositionTracksItsOwnSource() {
        // An action button must land where a plain button at the same
        // source spot would land. This pins the index bookkeeping in
        // the shared separation pass: reading the wrong slot yields a
        // plain button's position instead.
        let base = samplePortraitLayout()
        let spot = (x: 0.9, y: 0.1, size: 56.0)

        var withAction = base
        withAction.actionButtons = [
            ActionButtonSpec(action: "$pauseMenu", x: spot.x, y: spot.y, size: spot.size)
        ]
        var withButton = base
        withButton.buttons = (base.buttons ?? []) + [
            ButtonSpec(label: "P", key: "KeyP", x: spot.x, y: spot.y, size: spot.size)
        ]

        let derivedAction = OrientationDerivation.derive(
            from: withAction, sourceIsLandscape: false, metrics: metrics, defaultDpad: nil
        ).actionButtons?.first
        let derivedButton = OrientationDerivation.derive(
            from: withButton, sourceIsLandscape: false, metrics: metrics, defaultDpad: nil
        ).buttons?.last

        XCTAssertEqual(derivedAction?.x ?? .nan, derivedButton?.x ?? .nan, accuracy: 1e-9)
        XCTAssertEqual(derivedAction?.y ?? .nan, derivedButton?.y ?? .nan, accuracy: 1e-9)
    }

    func testActionOnlyLayoutDerives() {
        let source = TouchLayout(
            dpad: DPadSpec(x: 0.13, y: 0.72, size: 140),
            buttons: nil,
            actionButtons: [
                ActionButtonSpec(action: "$toggleFastForward", x: 0.9, y: 0.6, size: 56)
            ]
        )
        let derived = OrientationDerivation.derive(
            from: source, sourceIsLandscape: false, metrics: metrics, defaultDpad: nil)
        XCTAssertNil(derived.buttons)
        XCTAssertEqual(derived.actionButtons?.count, 1)
        XCTAssertEqual(derived.actionButtons?.first?.action, "$toggleFastForward")
    }

    func testMovementStyleCarriesThroughDerivation() {
        var portrait = samplePortraitLayout()
        portrait.dpad?.style = .stick
        let landscape = OrientationDerivation.derive(
            from: portrait, sourceIsLandscape: false, metrics: metrics, defaultDpad: nil)
        XCTAssertEqual(landscape.dpad?.style, .stick)
    }

    func testMissingActionButtonsStayMissing() {
        let portrait = samplePortraitLayout()
        let landscape = OrientationDerivation.derive(
            from: portrait,
            sourceIsLandscape: false,
            metrics: metrics,
            defaultDpad: nil
        )
        XCTAssertNil(landscape.actionButtons)
    }

    func testPortraitClusterDerivesLandscapePreservingSignsAndGaps() {
        let portrait = samplePortraitLayout()
        let landscape = OrientationDerivation.derive(
            from: portrait,
            sourceIsLandscape: false,
            metrics: metrics,
            defaultDpad: nil
        )

        assertDerivationPreservesArrangement(
            source: portrait,
            derived: landscape,
            sourceIsLandscape: false
        )
        assertWithinZone(layout: landscape, isLandscape: true)
        assertNoOverlaps(layout: landscape, isLandscape: true)
    }

    // The landscape source is hand-authored, NOT produced by the unit
    // under test: deriving from derivation output can only exercise
    // whatever shapes derive itself emits, so a landscape-source bug
    // could pass vacuously on well-formed derived input.
    func testLandscapeClusterDerivesPortraitPreservingSignsAndGaps() {
        let landscape = sampleLandscapeLayout()
        let derived = OrientationDerivation.derive(
            from: landscape,
            sourceIsLandscape: true,
            metrics: metrics,
            defaultDpad: nil
        )

        assertDerivationPreservesArrangement(
            source: landscape,
            derived: derived,
            sourceIsLandscape: true
        )
        assertWithinZone(layout: derived, isLandscape: false)
        assertNoOverlaps(layout: derived, isLandscape: false)
    }

    // Complementary round-trip property: deriving back from derived
    // output must also hold the invariants.
    func testPortraitDerivationRoundTripsThroughLandscape() {
        let portrait = samplePortraitLayout()
        let landscape = OrientationDerivation.derive(
            from: portrait,
            sourceIsLandscape: false,
            metrics: metrics,
            defaultDpad: nil
        )
        let roundTripPortrait = OrientationDerivation.derive(
            from: landscape,
            sourceIsLandscape: true,
            metrics: metrics,
            defaultDpad: nil
        )

        assertDerivationPreservesArrangement(
            source: landscape,
            derived: roundTripPortrait,
            sourceIsLandscape: true
        )
        assertWithinZone(layout: roundTripPortrait, isLandscape: false)
        assertNoOverlaps(layout: roundTripPortrait, isLandscape: false)
    }

    func testSourceWithoutDpadDerivesNilDpadAndClearsDefaultObstacle() {
        let source = TouchLayout(
            dpad: nil,
            buttons: [
                ButtonSpec(label: "OK", key: "KeyZ", x: 0.86, y: 0.80, size: 56),
                ButtonSpec(label: "Back", key: "KeyX", x: 0.74, y: 0.86, size: 56),
            ]
        )

        let defaultObstacle = (
            x: defaultDpad.landscapeX * metrics.landscapeWidth,
            y: defaultDpad.landscapeY * metrics.landscapeHeight,
            size: defaultDpad.size
        )
        let derived = OrientationDerivation.derive(
            from: source,
            sourceIsLandscape: false,
            metrics: metrics,
            defaultDpad: defaultObstacle
        )

        XCTAssertNil(derived.dpad)
        guard let buttons = derived.buttons else {
            XCTFail("expected buttons")
            return
        }
        assertNoOverlaps(layout: derived, isLandscape: true, extraObstacle: defaultObstacle)
        for button in buttons {
            let size = button.size ?? 56
            let center = (
                x: button.x * metrics.landscapeWidth,
                y: button.y * metrics.landscapeHeight
            )
            let required = (size + defaultObstacle.size) * 0.5 + ButtonSeparation.minimumGap
            XCTAssertGreaterThanOrEqual(
                distance(center, (defaultObstacle.x, defaultObstacle.y)),
                required - 1e-3
            )
        }
    }

    // MARK: - Completion semantics

    func testManifestWithOnlyPortraitCompletesToDerivationOutput() {
        let portrait = samplePortraitLayout()
        let section = TouchSection(portrait: portrait, landscape: nil)
        let (completed, involved) = TouchSectionCompletion.complete(
            section, metrics: metrics, defaultDpad: defaultDpad)

        XCTAssertTrue(involved)
        guard let landscape = completed.landscape else {
            XCTFail("expected landscape")
            return
        }
        // The equality below only pins the delegation plumbing (it
        // holds no matter what derive produces), so the completed
        // layout must independently satisfy the layout invariants.
        assertWithinZone(layout: landscape, isLandscape: true)
        assertNoOverlaps(layout: landscape, isLandscape: true)
        XCTAssertEqual(
            landscape,
            OrientationDerivation.derive(
                from: portrait,
                sourceIsLandscape: false,
                metrics: metrics,
                defaultDpad: (
                    x: defaultDpad.landscapeX * metrics.landscapeWidth,
                    y: defaultDpad.landscapeY * metrics.landscapeHeight,
                    size: defaultDpad.size
                )
            )
        )
    }

    func testExplicitEmptyOrientationDoesNotTriggerCompletion() {
        let portrait = samplePortraitLayout()
        let section = TouchSection(portrait: portrait, landscape: TouchLayout())
        let (completed, involved) = TouchSectionCompletion.complete(
            section, metrics: metrics, defaultDpad: defaultDpad)

        XCTAssertFalse(involved)
        XCTAssertNil(completed.landscape?.dpad)
        XCTAssertNil(completed.landscape?.buttons)
    }

    func testBothOrientationsPresentSkipsCompletion() {
        let section = TouchSection(
            portrait: samplePortraitLayout(),
            landscape: sampleLandscapeLayout()
        )
        let (completed, involved) = TouchSectionCompletion.complete(
            section, metrics: metrics, defaultDpad: defaultDpad)

        XCTAssertFalse(involved)
        XCTAssertEqual(completed, section)
    }

    // MARK: - Round-trip

    func testDerivedLayoutsSerializeAndReparse() throws {
        let portrait = samplePortraitLayout()
        let derived = OrientationDerivation.derive(
            from: portrait,
            sourceIsLandscape: false,
            metrics: metrics,
            defaultDpad: (
                x: defaultDpad.landscapeX * metrics.landscapeWidth,
                y: defaultDpad.landscapeY * metrics.landscapeHeight,
                size: defaultDpad.size
            )
        )

        let manifest = ControlsManifest(
            version: 1,
            touch: TouchSection(portrait: portrait, landscape: derived)
        )
        guard let data = ControlsManifestSerializer.serialize(touch: manifest.touch, controller: nil) else {
            XCTFail("expected serialized data")
            return
        }

        let parsed = ControlsManifestLoader.parse(data: data)
        XCTAssertTrue(parsed.findings.filter { $0.severity == .error }.isEmpty)
        guard let reparsed = parsed.manifest?.touch?.landscape else {
            XCTFail("expected landscape")
            return
        }
        XCTAssertEqual(reparsed.buttons?.map(\.key), derived.buttons?.map(\.key))
        XCTAssertNotNil(reparsed.dpad)
    }

    // MARK: - Fixtures

    private func samplePortraitLayout() -> TouchLayout {
        TouchLayout(
            dpad: DPadSpec(x: 0.14, y: 0.74, size: 140, opacity: 0.9),
            buttons: [
                ButtonSpec(label: "OK", key: "KeyZ", x: 0.88, y: 0.80, size: 68),
                ButtonSpec(label: "Back", key: "KeyX", x: 0.74, y: 0.86, size: 56),
                ButtonSpec(label: "Run", key: "ShiftLeft", x: 0.88, y: 0.62, size: 50, opacity: 0.8),
            ]
        )
    }

    /// Every element sits fully inside the landscape touch zone
    /// (center at least half a size away from every inset edge).
    /// Gap preservation only holds for legal layouts: an element that
    /// hangs into an inset gets pulled in by the target-side zone
    /// clamp, which legitimately compresses its gaps.
    private func sampleLandscapeLayout() -> TouchLayout {
        TouchLayout(
            dpad: DPadSpec(x: 0.16, y: 0.68, size: 140),
            buttons: [
                ButtonSpec(label: "OK", key: "KeyZ", x: 0.88, y: 0.72, size: 68),
                ButtonSpec(label: "Back", key: "KeyX", x: 0.78, y: 0.80, size: 56),
            ]
        )
    }

    // MARK: - Assertions

    private func assertDerivationPreservesArrangement(
        source: TouchLayout,
        derived: TouchLayout,
        sourceIsLandscape: Bool
    ) {
        guard let sourceButtons = source.buttons, let derivedButtons = derived.buttons else {
            XCTFail("expected buttons")
            return
        }
        XCTAssertEqual(sourceButtons.map(\.key), derivedButtons.map(\.key))

        let sourceWidth = metrics.width(isLandscape: sourceIsLandscape)
        let sourceHeight = metrics.height(isLandscape: sourceIsLandscape)
        let targetWidth = metrics.width(isLandscape: !sourceIsLandscape)
        let targetHeight = metrics.height(isLandscape: !sourceIsLandscape)

        let sourcePoints = sourceButtons.map { ($0.x * sourceWidth, $0.y * sourceHeight) }
        let derivedPoints = derivedButtons.map { ($0.x * targetWidth, $0.y * targetHeight) }

        let sourceLeading = metrics.leadingInset(isLandscape: sourceIsLandscape)
        let targetLeading = metrics.leadingInset(isLandscape: !sourceIsLandscape)
        let sourceMidX = sourceWidth * 0.5

        for index in 0..<sourcePoints.count {
            for other in (index + 1)..<sourcePoints.count {
                assertSameSign(
                    sourcePoints[index].0 - sourcePoints[other].0,
                    derivedPoints[index].0 - derivedPoints[other].0,
                    "dx between buttons \(index) and \(other)"
                )
                assertSameSign(
                    sourcePoints[index].1 - sourcePoints[other].1,
                    derivedPoints[index].1 - derivedPoints[other].1,
                    "dy between buttons \(index) and \(other)"
                )

                if sourcePoints[index].0 < sourceMidX && sourcePoints[other].0 < sourceMidX {
                    let sourceGap = abs(sourcePoints[index].0 - sourcePoints[other].0)
                    let derivedGap = abs(derivedPoints[index].0 - derivedPoints[other].0)
                    XCTAssertEqual(sourceGap, derivedGap, accuracy: 1.0, "left-half x gap")
                }
                if sourcePoints[index].0 >= sourceMidX && sourcePoints[other].0 >= sourceMidX {
                    let sourceGap = abs(sourcePoints[index].0 - sourcePoints[other].0)
                    let derivedGap = abs(derivedPoints[index].0 - derivedPoints[other].0)
                    XCTAssertEqual(sourceGap, derivedGap, accuracy: 1.0, "right-half x gap")
                }
            }
        }

        if let sourceDpad = source.dpad, let derivedDpad = derived.dpad {
            let sourceDpadPoint = (sourceDpad.x * sourceWidth, sourceDpad.y * sourceHeight)
            let derivedDpadPoint = (derivedDpad.x * targetWidth, derivedDpad.y * targetHeight)
            for (index, sourcePoint) in sourcePoints.enumerated() {
                assertSameSign(
                    sourceDpadPoint.0 - sourcePoint.0,
                    derivedDpadPoint.0 - derivedPoints[index].0,
                    "dpad dx vs button \(index)"
                )
                assertSameSign(
                    sourceDpadPoint.1 - sourcePoint.1,
                    derivedDpadPoint.1 - derivedPoints[index].1,
                    "dpad dy vs button \(index)"
                )
            }
        }

        _ = sourceLeading
        _ = targetLeading
    }

    private func assertWithinZone(layout: TouchLayout, isLandscape: Bool) {
        let width = metrics.width(isLandscape: isLandscape)
        let height = metrics.height(isLandscape: isLandscape)
        let top = metrics.topInset(isLandscape: isLandscape)
        let bottom = metrics.bottomInset(isLandscape: isLandscape)
        let leading = metrics.leadingInset(isLandscape: isLandscape)
        let trailing = metrics.trailingInset(isLandscape: isLandscape)

        if let buttons = layout.buttons {
            for button in buttons {
                XCTAssertGreaterThanOrEqual(button.x, OrientationDerivation.coordMin)
                XCTAssertLessThanOrEqual(button.x, OrientationDerivation.coordMax)
                XCTAssertGreaterThanOrEqual(button.y, OrientationDerivation.coordMin)
                XCTAssertLessThanOrEqual(button.y, OrientationDerivation.coordMax)

                let size = button.size ?? 56
                let centerX = button.x * width
                let centerY = button.y * height
                XCTAssertGreaterThanOrEqual(centerX - size * 0.5, leading - 1)
                XCTAssertLessThanOrEqual(centerX + size * 0.5, width - trailing + 1)
                XCTAssertGreaterThanOrEqual(centerY - size * 0.5, top - 1)
                XCTAssertLessThanOrEqual(centerY + size * 0.5, height - bottom + 1)
            }
        }

        if let dpad = layout.dpad {
            XCTAssertGreaterThanOrEqual(dpad.x, OrientationDerivation.coordMin)
            XCTAssertLessThanOrEqual(dpad.x, OrientationDerivation.coordMax)
            XCTAssertGreaterThanOrEqual(dpad.y, OrientationDerivation.coordMin)
            XCTAssertLessThanOrEqual(dpad.y, OrientationDerivation.coordMax)
        }
    }

    private func assertNoOverlaps(
        layout: TouchLayout,
        isLandscape: Bool,
        extraObstacle: (x: Double, y: Double, size: Double)? = nil
    ) {
        guard let buttons = layout.buttons else { return }
        let width = metrics.width(isLandscape: isLandscape)
        let height = metrics.height(isLandscape: isLandscape)

        var circles: [(x: Double, y: Double, size: Double)] = buttons.map {
            ($0.x * width, $0.y * height, $0.size ?? 56)
        }

        if let dpad = layout.dpad {
            circles.append((dpad.x * width, dpad.y * height, dpad.size ?? 140))
        } else if let extraObstacle {
            circles.append(extraObstacle)
        }

        for i in 0..<circles.count {
            for j in (i + 1)..<circles.count {
                let required = (circles[i].size + circles[j].size) * 0.5 + ButtonSeparation.minimumGap
                XCTAssertGreaterThanOrEqual(
                    distance((circles[i].x, circles[i].y), (circles[j].x, circles[j].y)),
                    required - 1e-3
                )
            }
        }
    }

    private func assertSameSign(_ lhs: Double, _ rhs: Double, _ label: String) {
        XCTAssertEqual(sign(lhs), sign(rhs), accuracy: 0, label)
    }

    private func sign(_ value: Double) -> Double {
        if abs(value) < 1e-6 { return 0 }
        return value > 0 ? 1 : -1
    }

    private func distance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

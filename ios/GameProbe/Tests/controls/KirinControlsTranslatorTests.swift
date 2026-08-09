import XCTest

@testable import GameProbe

final class KirinControlsTranslatorTests: XCTestCase {

    private static let referenceExampleJSON = """
        {
          "version": 1,
          "scale": 100,
          "opacity": 80,
          "diagonalMovement": false,
          "rightGrid": {
            "slots": [138, 40, null, 133, 36, null, null, null, null, 29, 47, 32, 54, 52, 66],
            "bgColors": [-1, -1, null, -1, -1, null, null, null, null, -1, -1, -1, -1, -1, -10257240],
            "textColors": [null, null, null, null, null, null, null, null, null, null, null, null, null, null, -1]
          },
          "leftGrid": {
            "slots": [48, 41, 142, 45, 51, 141],
            "bgColors": [-1, -1, -1, -1, -1, -1],
            "textColors": [null, null, null, null, null, null]
          }
        }
        """

    private let expectedKeys = [
        "F8", "KeyL", "F3", "KeyH", "KeyA", "KeyS", "KeyD", "KeyZ", "KeyX", "Enter",
        "KeyT", "KeyM", "F12", "KeyQ", "KeyW", "F11",
    ]

    private let metrics = TouchZoneMetrics.reference

    // MARK: - Reference example

    func testReferenceExampleProducesSixteenButtons() throws {
        let data = Self.referenceExampleJSON.data(using: .utf8)!
        let translation = KirinControlsTranslator.translate(data: data, metrics: metrics)

        XCTAssertNotNil(translation.manifest)
        XCTAssertNil(translation.manifest?.bindings)

        let portrait = translation.manifest?.touch?.portrait
        let landscape = translation.manifest?.touch?.landscape
        XCTAssertNotEqual(portrait, landscape)
        XCTAssertNotNil(portrait?.dpad)
        XCTAssertNotNil(landscape?.dpad)

        guard let portraitButtons = portrait?.buttons, let landscapeButtons = landscape?.buttons else {
            XCTFail("expected buttons")
            return
        }
        XCTAssertEqual(portraitButtons.count, 16)
        XCTAssertEqual(landscapeButtons.count, 16)
        XCTAssertEqual(portraitButtons.map(\.key), expectedKeys)
        XCTAssertEqual(landscapeButtons.map(\.key), expectedKeys)

        for button in portraitButtons + landscapeButtons {
            XCTAssertNil(button.label)
            XCTAssertEqual(button.opacity, 0.8)
        }

        for button in portraitButtons {
            XCTAssertGreaterThanOrEqual(button.size ?? 0, KirinControlsTranslator.minButtonSize)
            XCTAssertLessThanOrEqual(button.size ?? 0, 56)
        }

        assertGeometry(layout: portrait!, isLandscape: false)
        assertGeometry(layout: landscape!, isLandscape: true)
        assertArrangementEquality(portrait: portrait!, landscape: landscape!)
        assertRoundTrip(manifest: translation.manifest!)
    }

    func testWorstCaseFifteenPlusSixSlotsNonOverlap() throws {
        let rightSlots = (0..<15).map { _ in "29" }.joined(separator: ", ")
        let leftSlots = (0..<6).map { _ in "30" }.joined(separator: ", ")
        let json = """
            {
              "version": 1,
              "scale": 100,
              "opacity": 100,
              "rightGrid": { "slots": [\(rightSlots)] },
              "leftGrid": { "slots": [\(leftSlots)] }
            }
            """
        let translation = KirinControlsTranslator.translate(data: json.data(using: .utf8)!, metrics: metrics)
        guard let touch = translation.manifest?.touch else {
            XCTFail("expected manifest")
            return
        }

        XCTAssertEqual(touch.portrait?.buttons?.count, 21)
        XCTAssertEqual(touch.landscape?.buttons?.count, 21)
        assertGeometry(layout: touch.portrait!, isLandscape: false)
        assertGeometry(layout: touch.landscape!, isLandscape: true)
        assertArrangementEquality(portrait: touch.portrait!, landscape: touch.landscape!)
    }

    // MARK: - Round-trip

    func testRoundTripReferenceExample() throws {
        let data = Self.referenceExampleJSON.data(using: .utf8)!
        let translation = KirinControlsTranslator.translate(data: data, metrics: metrics)
        guard let manifest = translation.manifest else {
            XCTFail("expected manifest")
            return
        }
        assertRoundTrip(manifest: manifest)
    }

    func testRoundTripClampedEdgeFixture() throws {
        let json = """
            {
              "version": 1,
              "scale": 300,
              "opacity": 5,
              "rightGrid": { "slots": [29, 30, 31] }
            }
            """
        let translation = KirinControlsTranslator.translate(data: json.data(using: .utf8)!, metrics: metrics)
        guard let manifest = translation.manifest else {
            XCTFail("expected manifest")
            return
        }

        XCTAssertEqual(manifest.touch?.portrait?.buttons?.first?.size, 52)
        XCTAssertEqual(manifest.touch?.portrait?.buttons?.first?.opacity, 0.2)
        assertRoundTrip(manifest: manifest)
    }

    // MARK: - Android keycode table

    func testEveryMappedKeycodeExistsInKeyCodeTable() {
        for keycode in AndroidKeycodeTable.allMappedKeycodes {
            guard let code = AndroidKeycodeTable.w3cCode(for: keycode) else {
                XCTFail("missing mapping for \(keycode)")
                continue
            }
            XCTAssertNotNil(KeyCodeTable.scancode(for: code), "\(keycode) -> \(code)")
        }
    }

    func testAndroidKeycodeSpotChecks() {
        let checks: [(Int, String)] = [
            (7, "Digit0"),
            (16, "Digit9"),
            (23, "Enter"),
            (29, "KeyA"),
            (54, "KeyZ"),
            (67, "Backspace"),
            (111, "Escape"),
            (131, "F1"),
            (142, "F12"),
            (144, "Numpad0"),
        ]
        for (keycode, expected) in checks {
            XCTAssertEqual(AndroidKeycodeTable.w3cCode(for: keycode), expected)
        }

        XCTAssertNil(AndroidKeycodeTable.w3cCode(for: 999))
        XCTAssertNil(AndroidKeycodeTable.w3cCode(for: 4))
        XCTAssertNil(AndroidKeycodeTable.w3cCode(for: 24))
    }

    // MARK: - Clamps

    func testScaleAndOpacityClamps() {
        let lowScale = """
            { "rightGrid": { "slots": [29] }, "scale": 10 }
            """
        let highScale = """
            { "rightGrid": { "slots": [29] }, "scale": 300 }
            """
        let lowOpacity = """
            { "rightGrid": { "slots": [29] }, "opacity": 5 }
            """
        let highOpacity = """
            { "rightGrid": { "slots": [29] }, "opacity": 250 }
            """

        XCTAssertEqual(
            KirinControlsTranslator.translate(data: highScale.data(using: .utf8)!).manifest?
                .touch?.portrait?.buttons?.first?.size,
            52
        )
        XCTAssertEqual(
            KirinControlsTranslator.translate(data: lowScale.data(using: .utf8)!).manifest?
                .touch?.portrait?.buttons?.first?.size,
            40
        )
        XCTAssertEqual(
            KirinControlsTranslator.translate(data: lowOpacity.data(using: .utf8)!).manifest?
                .touch?.portrait?.buttons?.first?.opacity,
            0.2
        )
        XCTAssertEqual(
            KirinControlsTranslator.translate(data: highOpacity.data(using: .utf8)!).manifest?
                .touch?.portrait?.buttons?.first?.opacity,
            1.0
        )
    }

    // MARK: - Degradation

    func testVersionTwoIgnored() {
        let json = #"{"version": 2, "rightGrid": {"slots": [29]}}"#
        let translation = KirinControlsTranslator.translate(data: json.data(using: .utf8)!)
        XCTAssertNil(translation.manifest)
        XCTAssertTrue(translation.notes.contains { $0.contains("unsupported version 2") })
    }

    func testNonObjectJSONIgnored() {
        let translation = KirinControlsTranslator.translate(data: "[1,2,3]".data(using: .utf8)!)
        XCTAssertNil(translation.manifest)
        XCTAssertFalse(translation.notes.isEmpty)
    }

    func testUnmappedKeycodeDroppedWithNote() {
        let json = #"{"rightGrid": {"slots": [999, 29]}}"#
        let translation = KirinControlsTranslator.translate(data: json.data(using: .utf8)!)
        XCTAssertEqual(translation.manifest?.touch?.portrait?.buttons?.count, 1)
        XCTAssertTrue(translation.notes.contains { $0.contains("keycode 999") })
    }

    func testKirinStructuralCapacityTranslatesWhole() {
        // Kirin's own limit (15 right + 6 left slots) is the translation
        // cap. A full file translates with nothing dropped.
        let slots = (0..<20).map { _ in "29" }.joined(separator: ", ")
        let json = "{\"rightGrid\": {\"slots\": [\(slots)]}}"
        let translation = KirinControlsTranslator.translate(data: json.data(using: .utf8)!)
        XCTAssertEqual(translation.manifest?.touch?.portrait?.buttons?.count, 20)
        XCTAssertFalse(translation.notes.contains { $0.contains("dropped") })
    }

    func testAllNullSlotsIgnored() {
        let json = #"{"rightGrid": {"slots": [null, null]}, "leftGrid": {"slots": [null]}}"#
        let translation = KirinControlsTranslator.translate(data: json.data(using: .utf8)!)
        XCTAssertNil(translation.manifest)
        XCTAssertTrue(translation.notes.contains { $0.contains("no usable buttons") })
    }

    func testMissingVersionStillTranslates() {
        let json = #"{"rightGrid": {"slots": [29]}}"#
        let translation = KirinControlsTranslator.translate(data: json.data(using: .utf8)!)
        XCTAssertNotNil(translation.manifest)
    }

    // MARK: - Loader precedence

    private func makeTemporaryGameRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func kirinJSON(withSlots slots: String = "[29]") -> String {
        """
        {
          "version": 1,
          "scale": 100,
          "opacity": 100,
          "rightGrid": { "slots": \(slots) }
        }
        """
    }

    func testLoadKirinAlone() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try kirinJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(KirinControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .kirin)
        XCTAssertNotNil(outcome?.result.manifest?.touch)
        XCTAssertNil(outcome?.note)
    }

    func testLoadEmpoWinsOverKirin() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let empoDir = dir.appendingPathComponent("empo")
        try FileManager.default.createDirectory(at: empoDir, withIntermediateDirectories: true)
        try """
        { "version": 1, "controller": { "a": "Enter" } }
        """.data(using: .utf8)!.write(to: empoDir.appendingPathComponent("controls.json"))
        try kirinJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(KirinControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .empo)
        XCTAssertEqual(outcome?.note, .kirinSkippedBecauseManifestExists)
        XCTAssertNotNil(outcome?.result.manifest?.bindings)
    }

    func testLoadClaimedRootWinsOverKirin() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        { "version": 1, "controller": { "b": "Escape" } }
        """.data(using: .utf8)!.write(to: dir.appendingPathComponent("controls.json"))
        try kirinJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(KirinControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .root)
        XCTAssertEqual(outcome?.note, .kirinSkippedBecauseManifestExists)
        XCTAssertEqual(outcome?.result.manifest?.bindings?.entries[.element("b")], .key("Escape"))
    }

    func testLoadUnclaimedRootFallsThroughToKirin() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        { "touch": { "portrait": { "buttons": [] } } }
        """.data(using: .utf8)!.write(to: dir.appendingPathComponent("controls.json"))
        try kirinJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(KirinControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .kirin)
        XCTAssertNil(outcome?.note)
        XCTAssertNotNil(outcome?.result.manifest?.touch)
    }

    func testLoadRejectedEmpoDoesNotFallThroughToKirin() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let empoDir = dir.appendingPathComponent("empo")
        try FileManager.default.createDirectory(at: empoDir, withIntermediateDirectories: true)
        try """
        { "version": true, "touch": { "portrait": { "buttons": [] } } }
        """.data(using: .utf8)!.write(to: empoDir.appendingPathComponent("controls.json"))
        try kirinJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(KirinControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .empo)
        XCTAssertNil(outcome?.result.manifest)
        XCTAssertTrue(outcome?.result.findings.contains { $0.code == "V002" } == true)
    }

    func testKirinFindingsAreWarningsOnly() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try kirinJSON(withSlots: "[999]").data(using: .utf8)!.write(
            to: dir.appendingPathComponent(KirinControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .kirin)
        XCTAssertNil(outcome?.result.manifest)
        XCTAssertEqual(outcome?.result.findings.allSatisfy { $0.severity == .warning }, true)
        XCTAssertEqual(outcome?.result.findings.contains { $0.code == "K001" }, true)
    }

    func testLoadEmpoAndRootSkipsKirinNoteWhenBothApply() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let empoDir = dir.appendingPathComponent("empo")
        try FileManager.default.createDirectory(at: empoDir, withIntermediateDirectories: true)
        try """
        { "version": 1, "controller": { "a": "Enter" } }
        """.data(using: .utf8)!.write(to: empoDir.appendingPathComponent("controls.json"))
        try """
        { "version": 1, "controller": { "b": "Escape" } }
        """.data(using: .utf8)!.write(to: dir.appendingPathComponent("controls.json"))
        try kirinJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(KirinControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.note, .rootSkippedBecauseEmpoExists)
    }

    // MARK: - Geometry helpers

    private func assertRoundTrip(manifest: ControlsManifest) {
        let serialized = ControlsManifestSerializer.serialize(
            touch: manifest.touch,
            bindings: manifest.bindings
        )
        XCTAssertNotNil(serialized)
        let result = ControlsManifestLoader.parse(data: serialized!)
        XCTAssertNotNil(result.manifest)
        XCTAssertTrue(result.findings.filter { $0.severity == .error }.isEmpty)
    }

    private func assertGeometry(layout: TouchLayout, isLandscape: Bool) {
        guard let buttons = layout.buttons else {
            XCTFail("expected buttons")
            return
        }
        guard let dpad = layout.dpad else {
            XCTFail("expected dpad")
            return
        }

        let width = metrics.width(isLandscape: isLandscape)
        let height = metrics.height(isLandscape: isLandscape)

        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.x, KirinControlsTranslator.coordMin)
            XCTAssertLessThanOrEqual(button.x, KirinControlsTranslator.coordMax)
            XCTAssertGreaterThanOrEqual(button.y, KirinControlsTranslator.coordMin)
            XCTAssertLessThanOrEqual(button.y, KirinControlsTranslator.coordMax)
        }

        XCTAssertGreaterThanOrEqual(dpad.x, KirinControlsTranslator.coordMin)
        XCTAssertLessThanOrEqual(dpad.x, KirinControlsTranslator.coordMax)
        XCTAssertGreaterThanOrEqual(dpad.y, KirinControlsTranslator.coordMin)
        XCTAssertLessThanOrEqual(dpad.y, KirinControlsTranslator.coordMax)

        let dpadSize = dpad.size ?? KirinControlsTranslator.minDpadSize
        XCTAssertGreaterThanOrEqual(dpadSize, KirinControlsTranslator.minDpadSize)
        XCTAssertLessThanOrEqual(dpadSize, KirinControlsTranslator.maxDpadSize)

        XCTAssertTrue(
            pairwiseNonOverlapping(buttons: buttons, dpad: dpad, width: width, height: height),
            "buttons overlap d-pad or each other in \(isLandscape ? "landscape" : "portrait")"
        )

        assertWithinUsableZone(buttons: buttons, isLandscape: isLandscape)
        assertDpadWithinUsableZone(dpad: dpad, isLandscape: isLandscape)
        assertTopAnchored(layout: layout, isLandscape: isLandscape)

        let rightGrid = Array(buttons.prefix(buttons.count > 10 ? 10 : buttons.count))
        let leftGrid = buttons.count > 10 ? Array(buttons.suffix(6)) : []

        assertColumnPitchesEqual(buttons: rightGrid, width: width, height: height)
        if !leftGrid.isEmpty {
            assertColumnPitchesEqual(buttons: leftGrid, width: width, height: height)
            assertSharedRows(left: leftGrid, right: rightGrid, height: height)
            assertDpadOnLeftGridMiddleColumn(
                dpad: dpad, leftGrid: leftGrid, width: width, isLandscape: isLandscape)
            assertDpadBelowLeftGrid(
                dpad: dpad, leftGrid: leftGrid, height: height, dpadSize: dpadSize,
                isLandscape: isLandscape)
        }
    }

    private func assertArrangementEquality(portrait: TouchLayout, landscape: TouchLayout) {
        guard let portraitButtons = portrait.buttons, let landscapeButtons = landscape.buttons else {
            XCTFail("expected buttons")
            return
        }
        XCTAssertEqual(portraitButtons.map(\.key), landscapeButtons.map(\.key))

        let portraitWidth = metrics.portraitWidth
        let portraitHeight = metrics.portraitHeight
        let landscapeWidth = metrics.landscapeWidth
        let landscapeHeight = metrics.landscapeHeight

        let portraitPoints = portraitButtons.map { ($0.x * portraitWidth, $0.y * portraitHeight) }
        let landscapePoints = landscapeButtons.map { ($0.x * landscapeWidth, $0.y * landscapeHeight) }

        for index in 0..<portraitPoints.count {
            for other in (index + 1)..<portraitPoints.count {
                assertSameSign(
                    portraitPoints[index].0 - portraitPoints[other].0,
                    landscapePoints[index].0 - landscapePoints[other].0,
                    "dx between buttons \(index) and \(other)"
                )
                assertSameSign(
                    portraitPoints[index].1 - portraitPoints[other].1,
                    landscapePoints[index].1 - landscapePoints[other].1,
                    "dy between buttons \(index) and \(other)"
                )
            }
        }

        guard let portraitDpad = portrait.dpad, let landscapeDpad = landscape.dpad else {
            XCTFail("expected dpad")
            return
        }
        let portraitDpadPoint = (
            portraitDpad.x * portraitWidth, portraitDpad.y * portraitHeight
        )
        let landscapeDpadPoint = (
            landscapeDpad.x * landscapeWidth, landscapeDpad.y * landscapeHeight
        )

        for (index, portraitPoint) in portraitPoints.enumerated() {
            assertSameSign(
                portraitDpadPoint.0 - portraitPoint.0,
                landscapeDpadPoint.0 - landscapePoints[index].0,
                "dpad dx vs button \(index)"
            )
            assertSameSign(
                portraitDpadPoint.1 - portraitPoint.1,
                landscapeDpadPoint.1 - landscapePoints[index].1,
                "dpad dy vs button \(index)"
            )
        }
    }

    private func assertSameSign(_ lhs: Double, _ rhs: Double, _ label: String) {
        XCTAssertEqual(sign(lhs), sign(rhs), accuracy: 0, label)
    }

    private func sign(_ value: Double) -> Double {
        if abs(value) < 1e-6 { return 0 }
        return value > 0 ? 1 : -1
    }

    private func assertTopAnchored(layout: TouchLayout, isLandscape: Bool) {
        guard let buttons = layout.buttons, !buttons.isEmpty else { return }
        let height = metrics.height(isLandscape: isLandscape)
        let topInset = metrics.topInset(isLandscape: isLandscape)
        let bottomInset = metrics.bottomInset(isLandscape: isLandscape)
        let zoneMidY = (topInset + height - bottomInset) * 0.5
        let firstRowCenterY = buttons.map { $0.y * height }.min() ?? height
        XCTAssertLessThan(
            firstRowCenterY, zoneMidY,
            "first row should be top-anchored above zone midpoint in \(isLandscape ? "landscape" : "portrait")"
        )
    }

    private func assertWithinUsableZone(buttons: [ButtonSpec], isLandscape: Bool) {
        let height = metrics.height(isLandscape: isLandscape)
        let topInset = metrics.topInset(isLandscape: isLandscape)
        let bottomInset = metrics.bottomInset(isLandscape: isLandscape)
        for button in buttons {
            let size = button.size ?? KirinControlsTranslator.defaultButtonSize
            let centerY = button.y * height
            XCTAssertGreaterThanOrEqual(
                centerY - size * 0.5, topInset - 1,
                "button \(button.key) above usable zone in \(isLandscape ? "landscape" : "portrait")"
            )
            XCTAssertLessThanOrEqual(
                centerY + size * 0.5, height - bottomInset + 1,
                "button \(button.key) below usable zone in \(isLandscape ? "landscape" : "portrait")"
            )
        }
    }

    private func pairwiseNonOverlapping(
        buttons: [ButtonSpec],
        dpad: DPadSpec,
        width: Double,
        height: Double
    ) -> Bool {
        let dpadSize = dpad.size ?? KirinControlsTranslator.minDpadSize
        let dpadPoint = (x: dpad.x * width, y: dpad.y * height, size: dpadSize)

        let points = buttons.map { button in
            (
                x: button.x * width,
                y: button.y * height,
                size: button.size ?? KirinControlsTranslator.defaultButtonSize
            )
        }
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let required = (points[i].size + points[j].size) * 0.5
                let dist = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                if dist < required - 1e-3 { return false }
            }
            let required = (points[i].size + dpadPoint.size) * 0.5
            let dist = hypot(points[i].x - dpadPoint.x, points[i].y - dpadPoint.y)
            if dist < required - 1e-3 { return false }
        }
        return true
    }

    private func assertDpadWithinUsableZone(dpad: DPadSpec, isLandscape: Bool) {
        let height = metrics.height(isLandscape: isLandscape)
        let topInset = metrics.topInset(isLandscape: isLandscape)
        let bottomInset = metrics.bottomInset(isLandscape: isLandscape)
        let size = dpad.size ?? KirinControlsTranslator.minDpadSize
        let centerY = dpad.y * height
        XCTAssertGreaterThanOrEqual(centerY - size * 0.5, topInset - 1)
        XCTAssertLessThanOrEqual(centerY + size * 0.5, height - bottomInset + 1)
    }

    private func assertDpadOnLeftGridMiddleColumn(
        dpad: DPadSpec,
        leftGrid: [ButtonSpec],
        width: Double,
        isLandscape: Bool
    ) {
        let columnXs = Array(Set(leftGrid.map { $0.x * width })).sorted()
        let expectedX: Double
        if columnXs.count >= 2 {
            expectedX = columnXs[columnXs.count / 2]
        } else {
            let leadingInset = metrics.leadingInset(isLandscape: isLandscape)
            let buttonSize = leftGrid.first?.size ?? KirinControlsTranslator.defaultButtonSize
            let pitch = buttonSize + KirinControlsTranslator.cellGap
            expectedX = leadingInset + KirinControlsTranslator.edgeMargin + buttonSize * 0.5 + pitch
        }
        XCTAssertEqual(dpad.x * width, expectedX, accuracy: 2.0)
    }

    private func assertDpadBelowLeftGrid(
        dpad: DPadSpec,
        leftGrid: [ButtonSpec],
        height: Double,
        dpadSize: Double,
        isLandscape: Bool
    ) {
        let dpadTop = dpad.y * height - dpadSize * 0.5
        guard !leftGrid.isEmpty else {
            let bandTop = metrics.topInset(isLandscape: isLandscape) + KirinControlsTranslator.edgeMargin
            XCTAssertGreaterThanOrEqual(dpadTop, bandTop - 1)
            return
        }
        let bottomYs = leftGrid.map {
            ($0.y * height) + (($0.size ?? KirinControlsTranslator.defaultButtonSize) * 0.5)
        }
        let lastLeftBottom = bottomYs.max() ?? 0
        XCTAssertGreaterThanOrEqual(
            dpadTop, lastLeftBottom + KirinControlsTranslator.cellGap - 1)
    }

    private func assertColumnPitchesEqual(buttons: [ButtonSpec], width: Double, height: Double) {
        var rows: [Int: [ButtonSpec]] = [:]
        for button in buttons {
            let rowKey = Int(round(button.y * height / 10))
            rows[rowKey, default: []].append(button)
        }
        for rowButtons in rows.values where rowButtons.count >= 2 {
            let xs = rowButtons.map { $0.x * width }.sorted()
            let pitches = zip(xs.dropFirst(), xs).map { $0.0 - $0.1 }
            guard let firstPitch = pitches.first else { continue }
            for pitch in pitches.dropFirst() {
                XCTAssertEqual(pitch, firstPitch, accuracy: 1.0)
            }
        }
    }

    private func assertSharedRows(left: [ButtonSpec], right: [ButtonSpec], height: Double) {
        let leftRows = Dictionary(grouping: left) { Int(round($0.y * height / 10)) }
        let rightRows = Dictionary(grouping: right) { Int(round($0.y * height / 10)) }
        for (rowKey, leftButtons) in leftRows {
            guard let rightButtons = rightRows[rowKey] else { continue }
            let leftY = leftButtons.map(\.y).reduce(0, +) / Double(leftButtons.count)
            let rightY = rightButtons.map(\.y).reduce(0, +) / Double(rightButtons.count)
            XCTAssertEqual(leftY, rightY, accuracy: 0.001)
        }
    }
}

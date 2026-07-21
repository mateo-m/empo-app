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
        XCTAssertNil(translation.manifest?.controller)

        let portrait = translation.manifest?.touch?.portrait
        let landscape = translation.manifest?.touch?.landscape
        XCTAssertNotEqual(portrait, landscape)
        XCTAssertNil(portrait?.dpad)

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

        assertGeometry(layout: portrait!, isLandscape: false, expectBottomActionRow: true)
        assertGeometry(layout: landscape!, isLandscape: true, expectBottomActionRow: false)
        assertRoundTrip(manifest: translation.manifest!)
    }

    func testWorstCaseFifteenPlusSixSlotsNonOverlap() throws {
        let rightSlots = (0 ..< 15).map { _ in "29" }.joined(separator: ", ")
        let leftSlots = (0 ..< 6).map { _ in "30" }.joined(separator: ", ")
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
        assertGeometry(layout: touch.portrait!, isLandscape: false, expectBottomActionRow: false)
        assertGeometry(layout: touch.landscape!, isLandscape: true, expectBottomActionRow: false)
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

        XCTAssertEqual(manifest.touch?.portrait?.buttons?.first?.size, 100)
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
            100
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
        // cap; a fully populated file translates with nothing dropped.
        let slots = (0 ..< 20).map { _ in "29" }.joined(separator: ", ")
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
        XCTAssertNotNil(outcome?.result.manifest?.controller)
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
        XCTAssertEqual(outcome?.result.manifest?.controller?.entries["b"], .key("Escape"))
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
            controller: manifest.controller
        )
        XCTAssertNotNil(serialized)
        let result = ControlsManifestLoader.parse(data: serialized!)
        XCTAssertNotNil(result.manifest)
        XCTAssertTrue(result.findings.filter { $0.severity == .error }.isEmpty)
    }

    private func assertGeometry(layout: TouchLayout, isLandscape: Bool, expectBottomActionRow: Bool) {
        guard let buttons = layout.buttons else {
            XCTFail("expected buttons")
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

        XCTAssertTrue(
            pairwiseNonOverlapping(buttons: buttons, width: width, height: height),
            "buttons overlap in \(isLandscape ? "landscape" : "portrait")"
        )

        assertWithinUsableZone(buttons: buttons, isLandscape: isLandscape)

        let rightGrid = Array(buttons.prefix(10))
        let leftGrid = Array(buttons.suffix(6))

        assertColumnPitchesEqual(buttons: rightGrid, width: width, height: height)
        assertColumnPitchesEqual(buttons: leftGrid, width: width, height: height)

        if isLandscape {
            assertSharedLandscapeRows(left: leftGrid, right: rightGrid, height: height)
            XCTAssertGreaterThan(
                rightGrid.map { $0.x * width }.max() ?? 0,
                width * 0.75,
                "right grid should anchor on the right edge"
            )
            XCTAssertLessThan(
                leftGrid.map { $0.x * width }.min() ?? width,
                width * 0.25,
                "left grid should anchor on the left edge"
            )
        } else if expectBottomActionRow {
            let bottomRow = rightGrid.filter { ["KeyZ", "KeyX", "Enter"].contains($0.key) }
            XCTAssertEqual(bottomRow.count, 3)
            let bottomInset = metrics.portraitBottomInset
            let size = bottomRow[0].size ?? KirinControlsTranslator.defaultButtonSize
            let expectedBottomY =
                height - bottomInset - KirinControlsTranslator.edgeMargin - size * 0.5
            let bottomY = bottomRow.map { $0.y * height }
            XCTAssertTrue(bottomY.allSatisfy { abs($0 - expectedBottomY) < 2 })
        }
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
        width: Double,
        height: Double
    ) -> Bool {
        let points = buttons.map { button in
            (
                x: button.x * width,
                y: button.y * height,
                size: button.size ?? KirinControlsTranslator.defaultButtonSize
            )
        }
        for i in 0 ..< points.count {
            for j in (i + 1) ..< points.count {
                let required = (points[i].size + points[j].size) * 0.5
                let dist = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                if dist < required - 1e-3 { return false }
            }
        }
        return true
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

    private func assertSharedLandscapeRows(left: [ButtonSpec], right: [ButtonSpec], height: Double) {
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

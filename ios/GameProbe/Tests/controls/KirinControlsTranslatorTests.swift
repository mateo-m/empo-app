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

    // MARK: - Reference example

    func testReferenceExampleProducesSixteenButtons() throws {
        let data = Self.referenceExampleJSON.data(using: .utf8)!
        let translation = KirinControlsTranslator.translate(data: data)

        XCTAssertNotNil(translation.manifest)
        XCTAssertNil(translation.manifest?.controller)

        let portrait = translation.manifest?.touch?.portrait
        let landscape = translation.manifest?.touch?.landscape
        XCTAssertEqual(portrait, landscape)
        XCTAssertNil(portrait?.dpad)

        guard let buttons = portrait?.buttons else {
            XCTFail("expected buttons")
            return
        }
        XCTAssertEqual(buttons.count, 16)
        XCTAssertEqual(buttons.map(\.key), expectedKeys)

        for button in buttons {
            XCTAssertNil(button.label)
            XCTAssertEqual(button.size, 56)
            XCTAssertEqual(button.opacity, 0.8)
        }

        let bottomRow = buttons.filter { ["KeyZ", "KeyX", "Enter"].contains($0.key) }
        XCTAssertEqual(bottomRow.map(\.key), ["KeyZ", "KeyX", "Enter"])
        for button in bottomRow {
            XCTAssertEqual(button.y, 0.86, accuracy: 0.000_001)
        }
    }

    // MARK: - Round-trip

    func testRoundTripReferenceExample() throws {
        let data = Self.referenceExampleJSON.data(using: .utf8)!
        let translation = KirinControlsTranslator.translate(data: data)
        guard let manifest = translation.manifest else {
            XCTFail("expected manifest")
            return
        }

        let serialized = ControlsManifestSerializer.serialize(
            touch: manifest.touch,
            controller: manifest.controller
        )
        XCTAssertNotNil(serialized)

        let result = ControlsManifestLoader.parse(data: serialized!)
        XCTAssertNotNil(result.manifest)
        XCTAssertTrue(result.findings.filter { $0.severity == .error }.isEmpty)
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
        let translation = KirinControlsTranslator.translate(data: json.data(using: .utf8)!)
        guard let manifest = translation.manifest else {
            XCTFail("expected manifest")
            return
        }

        XCTAssertEqual(manifest.touch?.portrait?.buttons?.first?.size, 100)
        XCTAssertEqual(manifest.touch?.portrait?.buttons?.first?.opacity, 0.2)

        let serialized = ControlsManifestSerializer.serialize(
            touch: manifest.touch,
            controller: manifest.controller
        )
        let result = ControlsManifestLoader.parse(data: serialized!)
        XCTAssertTrue(result.findings.filter { $0.severity == .error }.isEmpty)
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

    func testMoreThanSixteenButtonsTruncated() {
        let slots = (0 ..< 20).map { _ in "29" }.joined(separator: ", ")
        let json = "{\"rightGrid\": {\"slots\": [\(slots)]}}"
        let translation = KirinControlsTranslator.translate(data: json.data(using: .utf8)!)
        XCTAssertEqual(translation.manifest?.touch?.portrait?.buttons?.count, 16)
        XCTAssertTrue(translation.notes.contains { $0.contains("4 buttons beyond") })
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
}

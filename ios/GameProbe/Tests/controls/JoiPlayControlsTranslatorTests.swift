import XCTest

@testable import GameProbe

final class JoiPlayControlsTranslatorTests: XCTestCase {

    // Every keycode maps to a key DIFFERENT from its slot default, so a
    // translator that ignored the file and emitted defaults would fail.
    private static let fullCustomJSON = """
        {
          "btnOpacity": 80,
          "btnScale": 100,
          "aKeyCode": 62,
          "bKeyCode": 67,
          "cKeyCode": 54,
          "xKeyCode": 30,
          "yKeyCode": 8,
          "zKeyCode": 135,
          "lKeyCode": 92,
          "rKeyCode": 93
        }
        """

    private let defaultKeys = [
        "Enter", "Escape", "ShiftLeft", "KeyA", "KeyS", "KeyD", "KeyQ", "KeyW",
    ]
    private let defaultLabels = ["C", "B", "A", "X", "Y", "Z", "L", "R"]
    private let defaultXs = [0.86, 0.73, 0.63, 0.63, 0.74, 0.86, 0.06, 0.94]
    private let defaultYs = [0.80, 0.72, 0.84, 0.60, 0.54, 0.60, 0.08, 0.08]
    private let defaultSizes = [60.0, 56.0, 50.0, 44.0, 44.0, 44.0, 44.0, 44.0]

    // MARK: - Defaults

    func testDefaultsProduceEightButtonsInTableOrder() throws {
        let json = #"{"btnScale": 100}"#
        let translation = JoiPlayControlsTranslator.translate(data: json.data(using: .utf8)!)

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
        XCTAssertEqual(buttons.count, 8)
        XCTAssertEqual(buttons.map(\.key), defaultKeys)
        XCTAssertEqual(buttons.map(\.label), defaultLabels)

        for (index, button) in buttons.enumerated() {
            XCTAssertEqual(button.x, defaultXs[index], accuracy: 0.000_001)
            XCTAssertEqual(button.y, defaultYs[index], accuracy: 0.000_001)
            XCTAssertEqual(button.size, defaultSizes[index])
            XCTAssertEqual(button.opacity, 1.0)
        }
    }

    // MARK: - Full custom

    func testFullCustomMapsAllKeycodes() throws {
        let translation = JoiPlayControlsTranslator.translate(
            data: Self.fullCustomJSON.data(using: .utf8)!)

        guard let buttons = translation.manifest?.touch?.portrait?.buttons else {
            XCTFail("expected buttons")
            return
        }
        XCTAssertEqual(buttons.count, 8)
        XCTAssertEqual(buttons.map(\.label), defaultLabels)
        XCTAssertEqual(
            buttons.map(\.key),
            ["KeyZ", "Backspace", "Space", "KeyB", "Digit1", "F5", "PageUp", "PageDown"]
        )
        XCTAssertEqual(buttons[0].opacity, 0.8)
    }

    // MARK: - Keycode mapping

    func testMappedCKeyCodeEmitsEnter() {
        let json = #"{"cKeyCode": 66}"#
        let translation = JoiPlayControlsTranslator.translate(data: json.data(using: .utf8)!)
        XCTAssertEqual(translation.manifest?.touch?.portrait?.buttons?.first?.key, "Enter")
        XCTAssertTrue(translation.notes.isEmpty)
    }

    func testUnmappedCKeyCodeFallsBackWithNote() {
        let json = #"{"cKeyCode": 999}"#
        let translation = JoiPlayControlsTranslator.translate(data: json.data(using: .utf8)!)
        XCTAssertEqual(translation.manifest?.touch?.portrait?.buttons?.first?.key, "Enter")
        XCTAssertTrue(translation.notes.contains { $0.contains("cKeyCode") && $0.contains("999") })
    }

    // MARK: - Clamps

    func testScaleAndOpacityClamps() {
        let highScale = #"{"btnScale": 300}"#
        let lowScale = #"{"btnScale": 10}"#
        let lowOpacity = #"{"btnOpacity": 5}"#
        let highOpacity = #"{"btnOpacity": 250}"#

        XCTAssertEqual(
            JoiPlayControlsTranslator.translate(data: highScale.data(using: .utf8)!).manifest?
                .touch?.portrait?.buttons?.first?.size,
            100
        )
        let lowScaleButtons = JoiPlayControlsTranslator.translate(data: lowScale.data(using: .utf8)!).manifest?
            .touch?.portrait?.buttons
        XCTAssertTrue(lowScaleButtons?.allSatisfy { $0.size == 40 } == true)
        XCTAssertEqual(
            JoiPlayControlsTranslator.translate(data: lowOpacity.data(using: .utf8)!).manifest?
                .touch?.portrait?.buttons?.first?.opacity,
            0.2
        )
        XCTAssertEqual(
            JoiPlayControlsTranslator.translate(data: highOpacity.data(using: .utf8)!).manifest?
                .touch?.portrait?.buttons?.first?.opacity,
            1.0
        )
    }

    // MARK: - Claim rule

    func testEmptyObjectIgnored() {
        let translation = JoiPlayControlsTranslator.translate(data: "{}".data(using: .utf8)!)
        XCTAssertNil(translation.manifest)
        XCTAssertTrue(translation.notes.contains { $0.contains("no JoiPlay keys") })
    }

    func testUnknownKeysIgnored() {
        let translation = JoiPlayControlsTranslator.translate(data: #"{"foo": 1}"#.data(using: .utf8)!)
        XCTAssertNil(translation.manifest)
        XCTAssertTrue(translation.notes.contains { $0.contains("no JoiPlay keys") })
    }

    func testNonObjectJSONIgnored() {
        let translation = JoiPlayControlsTranslator.translate(data: "[1,2]".data(using: .utf8)!)
        XCTAssertNil(translation.manifest)
        XCTAssertFalse(translation.notes.isEmpty)
    }

    // MARK: - Round-trip

    func testRoundTripTranslatedManifest() throws {
        let translation = JoiPlayControlsTranslator.translate(
            data: Self.fullCustomJSON.data(using: .utf8)!)
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

    // MARK: - Loader precedence

    private func makeTemporaryGameRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func joiplayJSON(withKeycodes keycodes: String = "") -> String {
        if keycodes.isEmpty {
            return #"{"btnScale": 100}"#
        }
        return #"{"btnScale": 100, \#(keycodes)}"#
    }

    private func kirinJSON() -> String {
        """
        {
          "version": 1,
          "scale": 100,
          "opacity": 100,
          "rightGrid": { "slots": [29] }
        }
        """
    }

    func testLoadJoiplayAlone() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try joiplayJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(JoiPlayControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .joiplay)
        XCTAssertEqual(outcome?.result.manifest?.touch?.portrait?.buttons?.count, 8)
        XCTAssertNil(outcome?.note)
    }

    func testLoadKirinWinsOverJoiplay() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try kirinJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(KirinControlsTranslator.fileName))
        try joiplayJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(JoiPlayControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .kirin)
        XCTAssertEqual(outcome?.note, .joiplaySkippedBecauseOtherSourceExists)
    }

    func testLoadEmpoWinsOverJoiplay() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let empoDir = dir.appendingPathComponent("empo")
        try FileManager.default.createDirectory(at: empoDir, withIntermediateDirectories: true)
        try """
            { "version": 1, "controller": { "a": "Enter" } }
            """.data(using: .utf8)!.write(to: empoDir.appendingPathComponent("controls.json"))
        try joiplayJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(JoiPlayControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .empo)
        XCTAssertEqual(outcome?.note, .joiplaySkippedBecauseOtherSourceExists)
    }

    func testLoadClaimedRootWinsOverJoiplay() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
            { "version": 1, "controller": { "b": "Escape" } }
            """.data(using: .utf8)!.write(to: dir.appendingPathComponent("controls.json"))
        try joiplayJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(JoiPlayControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .root)
        XCTAssertEqual(outcome?.note, .joiplaySkippedBecauseOtherSourceExists)
    }

    func testLoadUnclaimedRootFallsThroughToJoiplay() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
            { "touch": { "portrait": { "buttons": [] } } }
            """.data(using: .utf8)!.write(to: dir.appendingPathComponent("controls.json"))
        try joiplayJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(JoiPlayControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .joiplay)
        XCTAssertNil(outcome?.note)
    }

    func testLoadRejectedEmpoDoesNotFallThroughToJoiplay() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let empoDir = dir.appendingPathComponent("empo")
        try FileManager.default.createDirectory(at: empoDir, withIntermediateDirectories: true)
        try """
            { "version": true, "touch": { "portrait": { "buttons": [] } } }
            """.data(using: .utf8)!.write(to: empoDir.appendingPathComponent("controls.json"))
        try joiplayJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(JoiPlayControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .empo)
        XCTAssertNil(outcome?.result.manifest)
        XCTAssertTrue(outcome?.result.findings.contains { $0.code == "V002" } == true)
    }

    func testLoadUnusableKirinDoesNotFallThroughToJoiplay() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
            { "version": 2, "rightGrid": { "slots": [29] } }
            """.data(using: .utf8)!.write(
                to: dir.appendingPathComponent(KirinControlsTranslator.fileName))
        try joiplayJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(JoiPlayControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .kirin)
        XCTAssertNil(outcome?.result.manifest)
    }

    func testLoadEmpoKirinJoiplayNotePriority() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let empoDir = dir.appendingPathComponent("empo")
        try FileManager.default.createDirectory(at: empoDir, withIntermediateDirectories: true)
        try """
            { "version": 1, "controller": { "a": "Enter" } }
            """.data(using: .utf8)!.write(to: empoDir.appendingPathComponent("controls.json"))
        try kirinJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(KirinControlsTranslator.fileName))
        try joiplayJSON().data(using: .utf8)!.write(
            to: dir.appendingPathComponent(JoiPlayControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .empo)
        XCTAssertEqual(outcome?.note, .kirinSkippedBecauseManifestExists)
    }

    func testJoiplayFindingsAreWarningsOnly() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try #"{"cKeyCode": 999}"#.data(using: .utf8)!.write(
            to: dir.appendingPathComponent(JoiPlayControlsTranslator.fileName))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .joiplay)
        XCTAssertNotNil(outcome?.result.manifest)
        XCTAssertEqual(outcome?.result.findings.allSatisfy { $0.severity == .warning }, true)
        XCTAssertEqual(outcome?.result.findings.contains { $0.code == "J001" }, true)
    }
}

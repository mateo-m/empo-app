import XCTest

@testable import GameProbe

final class ControlsManifestLoaderTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        #if SWIFT_PACKAGE
        guard let base = Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures/controls/\(name)"),
            FileManager.default.fileExists(atPath: base.path)
        else {
            XCTFail("missing fixture: \(name)")
            return URL(fileURLWithPath: "/")
        }
        return base
        #else
        let bundle = Bundle(for: ControlsManifestLoaderTests.self)
        if let base = bundle.resourceURL?
            .appendingPathComponent("Fixtures/controls/\(name)"),
            FileManager.default.fileExists(atPath: base.path)
        {
            return base
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/controls/\(name)")
        #endif
    }

    private func loadFixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private func finding(
        _ result: ControlsManifestLoader.Result,
        code: String,
        path: String
    ) -> ControlsManifestLoader.Finding? {
        result.findings.first { $0.code == code && $0.path == path }
    }

    func testSpecExampleParsesWithZeroFindings() throws {
        let data = try loadFixture("spec-example.json5")
        let result = ControlsManifestLoader.parse(data: data)

        XCTAssertNotNil(result.manifest)
        XCTAssertFalse(result.ignoredNewerVersion)
        XCTAssertTrue(result.findings.isEmpty)
        guard let manifest = result.manifest else {
            XCTFail("expected manifest")
            return
        }

        XCTAssertEqual(manifest.version, 1)

        let portrait = manifest.touch?.portrait
        XCTAssertEqual(portrait?.dpad, DPadSpec(x: 0.14, y: 0.74, size: 150, opacity: 0.9))
        XCTAssertEqual(portrait?.buttons?.count, 4)
        XCTAssertEqual(
            portrait?.buttons?[0],
            ButtonSpec(label: "OK", key: "KeyZ", x: 0.88, y: 0.80, size: 68, opacity: nil)
        )
        XCTAssertEqual(
            portrait?.buttons?[1],
            ButtonSpec(label: "Back", key: "KeyX", x: 0.74, y: 0.86, size: 56, opacity: nil)
        )
        XCTAssertEqual(
            portrait?.buttons?[2],
            ButtonSpec(label: "Run", key: "ShiftLeft", x: 0.88, y: 0.62, size: 50, opacity: 0.8)
        )
        XCTAssertEqual(
            portrait?.buttons?[3],
            ButtonSpec(label: "Log", key: "KeyQ", x: 0.06, y: 0.06, size: 44, opacity: 0.5)
        )

        let landscape = manifest.touch?.landscape
        XCTAssertEqual(landscape?.dpad, DPadSpec(x: 0.10, y: 0.68, size: nil, opacity: nil))
        XCTAssertEqual(landscape?.buttons?.count, 2)
        XCTAssertEqual(
            landscape?.buttons?[0],
            ButtonSpec(label: "OK", key: "KeyZ", x: 0.92, y: 0.72, size: 68, opacity: nil)
        )
        XCTAssertEqual(
            landscape?.buttons?[1],
            ButtonSpec(label: "Back", key: "KeyX", x: 0.82, y: 0.84, size: 56, opacity: nil)
        )

        XCTAssertEqual(manifest.controller?.entries["y"], .key("F5"))
        XCTAssertEqual(manifest.controller?.entries["righttrigger"], .key("ShiftLeft"))
    }

    func testV000InvalidJSON() throws {
        let data = try loadFixture("v000-invalid-json.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V000", path: ""))
    }

    func testV001OversizedFile() {
        let data = Data(count: 128 * 1024 + 1)
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V001", path: ""))
    }

    func testV002MissingVersion() throws {
        let data = try loadFixture("v002-missing-version.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V002", path: "/version"))
    }

    func testV002BadVersionType() throws {
        let data = try loadFixture("v002-bad-version.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V002", path: "/version"))
    }

    func testV010UnknownKey() throws {
        let data = try loadFixture("v010-unknown-key.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        let finding = finding(result, code: "V010", path: "/touch/portrait/buttons/0/key")
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.message.contains("NotARealKey") == true)
    }

    func testV011CoordinateRange() throws {
        let data = try loadFixture("v011-coord-range.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V011", path: "/touch/portrait/buttons/0/x"))
    }

    func testV012SizeOpacityRange() throws {
        let data = try loadFixture("v012-size-opacity.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V012", path: "/touch/portrait/buttons/0/size"))
    }

    func testV013TooManyButtons() throws {
        let data = try loadFixture("v013-too-many-buttons.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V013", path: "/touch/portrait/buttons"))
    }

    func testV014ActionInTouchButton() throws {
        let data = try loadFixture("v014-action-in-touch.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        let finding = finding(result, code: "V014", path: "/touch/portrait/buttons/0/key")
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.message.contains("$pauseMenu") == true)
    }

    func testV020UnknownControllerElement() throws {
        let data = try loadFixture("v020-unknown-element.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V020", path: "/controller/notabutton"))
    }

    func testV021UnknownAction() throws {
        let data = try loadFixture("v021-unknown-action.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        let finding = finding(result, code: "V021", path: "/controller/start")
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.message.contains("$notAnAction") == true)
    }

    func testW001EmptyManifest() throws {
        let data = try loadFixture("w001-empty.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNotNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "W001", path: ""))
    }

    func testW002LabelTruncationInModel() throws {
        let data = try loadFixture("w002-label-truncate.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNotNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "W002", path: "/touch/portrait/buttons/0/label"))
        XCTAssertEqual(result.manifest?.touch?.portrait?.buttons?.first?.label, "VeryLong")
    }

    func testW003DuplicateKeyStillYieldsManifest() throws {
        let data = try loadFixture("w003-duplicate-key.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNotNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "W003", path: "/touch/portrait/buttons"))
        XCTAssertEqual(result.manifest?.touch?.portrait?.buttons?.count, 2)
    }

    func testBooleanVersionRejected() {
        let json = #"{ "version": true }"#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNil(result.manifest)
        XCTAssertFalse(result.ignoredNewerVersion)
        XCTAssertNotNil(finding(result, code: "V002", path: "/version"))
    }

    func testBooleanCoordinateRejected() {
        let json = #"""
            { "version": 1, "touch": { "portrait": {
              "buttons": [ { "key": "Enter", "x": true, "y": 0.5 } ] } } }
            """#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V011", path: "/touch/portrait/buttons/0/x"))
    }

    func testVersion2IgnoredWithoutFindings() throws {
        let data = try loadFixture("version2.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        XCTAssertTrue(result.ignoredNewerVersion)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testUnknownKeysSilentlyIgnored() throws {
        let data = try loadFixture("unknown-keys.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNotNil(result.manifest)
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.manifest?.controller?.entries["a"], .key("Enter"))
    }

    func testEmptyButtonsDistinctFromNil() throws {
        let data = try loadFixture("empty-buttons.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNotNil(result.manifest)
        XCTAssertEqual(result.manifest?.touch?.portrait?.buttons, [])
    }

    func testLoadReturnsNilForMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(ControlsManifestLoader.load(gameRoot: dir))
    }

    func testLoadReadsManifestFromEmpoDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let empoDir = dir.appendingPathComponent("empo")
        try FileManager.default.createDirectory(at: empoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
            { "version": 1, "controller": { "a": "Enter" } }
            """
        try json.data(using: .utf8)!.write(to: empoDir.appendingPathComponent("controls.json"))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.result.location, .empo)
        XCTAssertNil(outcome?.note)
        XCTAssertEqual(outcome?.result.manifest?.controller?.entries["a"], .key("Enter"))
    }

    func testLoadResolvesRootOnlyManifest() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
            { "version": 1, "controller": { "a": "Enter" } }
            """
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("controls.json"))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.result.location, .root)
        XCTAssertNil(outcome?.note)
        XCTAssertEqual(outcome?.result.manifest?.controller?.entries["a"], .key("Enter"))
    }

    func testLoadPrefersEmpoWhenBothLocationsExist() throws {
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

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .empo)
        XCTAssertEqual(outcome?.note, .rootSkippedBecauseEmpoExists)
        XCTAssertEqual(outcome?.result.manifest?.controller?.entries["a"], .key("Enter"))
    }

    func testLoadSurfacesEmpoErrorsWhenRootWouldBeValid() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let empoDir = dir.appendingPathComponent("empo")
        try FileManager.default.createDirectory(at: empoDir, withIntermediateDirectories: true)

        try Data(contentsOf: fixtureURL("v002-missing-version.json5")).write(
            to: empoDir.appendingPathComponent("controls.json"))
        try """
            { "version": 1, "controller": { "a": "Enter" } }
            """.data(using: .utf8)!.write(to: dir.appendingPathComponent("controls.json"))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .empo)
        XCTAssertEqual(outcome?.note, .rootSkippedBecauseEmpoExists)
        XCTAssertNil(outcome?.result.manifest)
        XCTAssertNotNil(finding(outcome!.result, code: "V002", path: "/version"))
    }

    func testLoadIgnoresRootWithoutVersion() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
            { "touch": { "portrait": { "buttons": [] } } }
            """.data(using: .utf8)!.write(to: dir.appendingPathComponent("controls.json"))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.note, .rootUnclaimedNoVersion)
        XCTAssertNil(outcome?.result.manifest)
        XCTAssertTrue(outcome?.result.findings.isEmpty == true)
        XCTAssertNil(outcome?.result.location)
    }

    func testLoadValidatesClaimedRootManifest() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(contentsOf: fixtureURL("v010-unknown-key.json5")).write(
            to: dir.appendingPathComponent("controls.json"))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .root)
        XCTAssertNil(outcome?.note)
        XCTAssertNil(outcome?.result.manifest)
        XCTAssertNotNil(
            finding(outcome!.result, code: "V010", path: "/touch/portrait/buttons/0/key"))
    }

    func testLoadTreatsOversizedRootAsUnclaimed() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        var data = Data(count: 128 * 1024 + 1)
        data[0] = UInt8(ascii: "{")
        data[1] = UInt8(ascii: "\"")
        data[2] = UInt8(ascii: "v")
        try data.write(to: dir.appendingPathComponent("controls.json"))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.note, .rootUnclaimedOversized)
        XCTAssertNil(outcome?.result.manifest)
        XCTAssertTrue(outcome?.result.findings.isEmpty == true)
    }

    func testLoadOversizedEmpoStillReturnsV001() throws {
        let dir = try makeTemporaryGameRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let empoDir = dir.appendingPathComponent("empo")
        try FileManager.default.createDirectory(at: empoDir, withIntermediateDirectories: true)
        try Data(count: 128 * 1024 + 1).write(
            to: empoDir.appendingPathComponent("controls.json"))

        let outcome = ControlsManifestLoader.load(gameRoot: dir)
        XCTAssertEqual(outcome?.result.location, .empo)
        XCTAssertNil(outcome?.note)
        XCTAssertNotNil(finding(outcome!.result, code: "V001", path: ""))
    }

    private func makeTemporaryGameRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

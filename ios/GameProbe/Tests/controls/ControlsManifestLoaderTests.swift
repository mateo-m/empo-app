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

        // Same ulp caveat as the landscape "Back" button below: the
        // fixture decimals parse a platform-dependent ulp off, so the
        // numeric fields compare with a tolerance.
        let actionButton = portrait?.actionButtons?.first
        XCTAssertEqual(portrait?.actionButtons?.count, 1)
        XCTAssertEqual(actionButton?.action, "$toggleFastForward")
        XCTAssertEqual(actionButton?.x ?? .nan, 0.94, accuracy: 1e-9)
        XCTAssertEqual(actionButton?.y ?? .nan, 0.06, accuracy: 1e-9)
        XCTAssertEqual(actionButton?.size, 44)
        XCTAssertEqual(actionButton?.opacity ?? .nan, 0.6, accuracy: 1e-9)

        let landscape = manifest.touch?.landscape
        XCTAssertEqual(landscape?.dpad, DPadSpec(x: 0.10, y: 0.68, size: nil, opacity: nil))
        XCTAssertEqual(landscape?.buttons?.count, 2)
        XCTAssertEqual(
            landscape?.buttons?[0],
            ButtonSpec(label: "OK", key: "KeyZ", x: 0.92, y: 0.72, size: 68, opacity: nil)
        )
        // The loader parses with the engine's json5pp, which builds
        // fractions with pow(10, -n). The parsed double lands within
        // an ulp of the fixture text `0.82`, and WHICH ulp differs
        // per platform (Apple arm64 and glibc x86_64 disagree). The
        // x coordinate therefore compares with a tolerance.
        let back = landscape?.buttons?[1]
        XCTAssertEqual(back?.label, "Back")
        XCTAssertEqual(back?.key, "KeyX")
        XCTAssertEqual(back?.x ?? .nan, 0.82, accuracy: 1e-9)
        XCTAssertEqual(back?.y, 0.84)
        XCTAssertEqual(back?.size, 56)
        XCTAssertNil(back?.opacity)

        XCTAssertEqual(manifest.bindings?.entries[.element("y")], .key("F5"))
        XCTAssertEqual(manifest.bindings?.entries[.element("righttrigger")], .key("ShiftLeft"))
    }

    func testV000InvalidJSON() throws {
        let data = try loadFixture("v000-invalid-json.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        let finding = finding(result, code: "V000", path: "")
        XCTAssertNotNil(finding)
        // The finding must carry the json5pp error position so the
        // controls.json.log diagnostics name the broken line.
        XCTAssertTrue(
            finding?.message.contains("line") == true,
            "message lacks a position: \(finding?.message ?? "nil")"
        )
        XCTAssertTrue(
            finding?.message.contains("column") == true,
            "message lacks a position: \(finding?.message ?? "nil")"
        )
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
        // The message must point at the right fix.
        XCTAssertTrue(finding?.message.contains("actionButtons") == true)
    }

    func testV020UnknownControllerElement() throws {
        let data = try loadFixture("v020-unknown-element.json5")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V020", path: "/controller/notabutton"))
    }

    func testW005UnknownControllerActionKeepsEntry() throws {
        let data = try loadFixture("v021-unknown-action.json5")
        let result = ControlsManifestLoader.parse(data: data)
        // The file loads. The unknown binding stays in the map so a
        // load-modify-save cycle cannot strip it from disk.
        XCTAssertNotNil(result.manifest)
        let finding = finding(result, code: "W005", path: "/controller/start")
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.message.contains("$notAnAction") == true)
        XCTAssertEqual(result.manifest?.bindings?.entries[.element("start")], .action("$notAnAction"))
    }

    func testKnownControllerActionsParseWithoutFindings() {
        let entries = EmpoActionCatalog.all.map(\.id).enumerated()
            .map { index, id in
                "\"\(ControllerElement.allElements[index])\": \"\(id)\""
            }
            .joined(separator: ", ")
        let json = "{ \"version\": 1, \"controller\": { \(entries) } }"
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNotNil(result.manifest)
        XCTAssertTrue(result.findings.isEmpty, "\(result.findings)")
        XCTAssertEqual(result.manifest?.bindings?.entries.count, EmpoActionCatalog.all.count)
    }

    func testKeySourcesParseInTheBindingsSection() {
        let json = #"""
            { "version": 1, "bindings": {
              "KeyB": "Escape", "KeyJ": "a", "Enter": "$pauseMenu", "KeyM": null } }
            """#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertTrue(result.findings.isEmpty, "\(result.findings)")
        let bindings = result.manifest?.bindings
        XCTAssertEqual(bindings?.entries[.key("KeyB")], .key("Escape"))
        XCTAssertEqual(bindings?.entries[.key("KeyJ")], .element("a"))
        XCTAssertEqual(bindings?.entries[.key("Enter")], .action("$pauseMenu"))
        XCTAssertEqual(bindings?.entries[.key("KeyM")], .unbound)
    }

    func testControllerSectionStaysValidUnderItsOldName() {
        let json = #"{ "version": 1, "controller": { "a": "KeyZ" } }"#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertTrue(result.findings.isEmpty, "\(result.findings)")
        XCTAssertEqual(result.manifest?.bindings?.entries[.element("a")], .key("KeyZ"))
    }

    func testW007BothSectionNamesPresent() {
        let json = #"""
            { "version": 1, "bindings": { "a": "KeyZ" }, "controller": { "a": "KeyX" } }
            """#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNotNil(finding(result, code: "W007", path: "/controller"))
        XCTAssertEqual(result.manifest?.bindings?.entries[.element("a")], .key("KeyZ"))
    }

    func testV020UnknownBindingSource() {
        let json = #"{ "version": 1, "bindings": { "AnyKey": "Enter" } }"#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V020", path: "/bindings/AnyKey"))
    }

    func testV010UnknownKeySourceTarget() {
        let json = #"{ "version": 1, "bindings": { "KeyB": "AnyKey" } }"#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V010", path: "/bindings/KeyB"))
    }

    func testV023ElementCannotTargetAnElement() {
        let json = #"{ "version": 1, "bindings": { "x": "a" } }"#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V023", path: "/bindings/x"))
    }

    func testV000BindingsSectionMustBeAnObject() {
        let json = #"{ "version": 1, "bindings": [] }"#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V000", path: "/bindings"))
    }

    func testBindingsOnlyManifestIsNotEmpty() {
        let json = #"{ "version": 1, "bindings": { "KeyB": "Escape" } }"#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNotNil(result.manifest)
        XCTAssertNil(finding(result, code: "W001", path: ""))
    }

    func testElementAndKeyVocabulariesStayDisjoint() {
        // One map holds both source kinds. The day a key code equals
        // an element name, the loader could not tell them apart.
        let elements = ControllerElement.allNames
        for code in KeyCodeTable.allCodes {
            XCTAssertFalse(elements.contains(code), "\(code) is both a key and an element")
        }
    }

    func testActionButtonsParse() {
        let json = #"""
            { "version": 1, "touch": { "portrait": {
              "dpad": { "x": 0.14, "y": 0.74 },
              "actionButtons": [
                { "action": "$toggleFastForward", "x": 0.75, "y": 0.25, "size": 56, "opacity": 0.5 }
              ] } } }
            """#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNotNil(result.manifest)
        XCTAssertTrue(result.findings.isEmpty, "\(result.findings)")
        // Exact binary fractions only: the json5pp parser builds other
        // decimals a platform-dependent ulp off.
        XCTAssertEqual(
            result.manifest?.touch?.portrait?.actionButtons,
            [ActionButtonSpec(action: "$toggleFastForward", x: 0.75, y: 0.25, size: 56, opacity: 0.5)]
        )
    }

    func testW004UnknownTouchActionSkipsOnlyThatButton() {
        let json = #"""
            { "version": 1, "touch": { "portrait": {
              "actionButtons": [
                { "action": "$notAnAction", "x": 0.5, "y": 0.5 },
                { "action": "$pauseMenu", "x": 0.75, "y": 0.5 }
              ] } } }
            """#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNotNil(result.manifest)
        let finding = finding(result, code: "W004", path: "/touch/portrait/actionButtons/0/action")
        XCTAssertNotNil(finding)
        XCTAssertEqual(
            result.manifest?.touch?.portrait?.actionButtons,
            [ActionButtonSpec(action: "$pauseMenu", x: 0.75, y: 0.5)]
        )
    }

    func testW004ControllerOnlyActionSkippedInTouch() {
        let json = #"""
            { "version": 1, "touch": { "portrait": {
              "actionButtons": [
                { "action": "$toggleTouchControls", "x": 0.5, "y": 0.5 }
              ] } } }
            """#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNotNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "W004", path: "/touch/portrait/actionButtons/0/action"))
        XCTAssertEqual(result.manifest?.touch?.portrait?.actionButtons, [])
    }

    private func combinedCapJSON(buttons: Int, actions: Int) -> String {
        let keys = [
            "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ",
            "KeyK", "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT",
        ]
        let buttonEntries = (0..<buttons).map { index in
            "{ \"key\": \"\(keys[index])\", \"x\": 0.5, \"y\": 0.5 }"
        }.joined(separator: ", ")
        let actionEntries = (0..<actions).map { index in
            "{ \"action\": \"$pauseMenu\", \"x\": 0.\(index + 1), \"y\": 0.5 }"
        }.joined(separator: ", ")
        return """
            { "version": 1, "touch": { "portrait": {
              "buttons": [ \(buttonEntries) ],
              "actionButtons": [ \(actionEntries) ] } } }
            """
    }

    func testV015CombinedCapExceeded() {
        let json = combinedCapJSON(buttons: 20, actions: 2)
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V015", path: "/touch/portrait"))
        // The per-array V013 must not fire: neither list exceeds 21 alone.
        XCTAssertNil(finding(result, code: "V013", path: "/touch/portrait/buttons"))
    }

    func testV015CombinedCapAtLimitPasses() {
        let json = combinedCapJSON(buttons: 19, actions: 2)
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNotNil(result.manifest)
        XCTAssertNil(finding(result, code: "V015", path: "/touch/portrait"))
    }

    func testV015ActionButtonsAloneExceedCap() {
        let json = combinedCapJSON(buttons: 0, actions: 22)
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V015", path: "/touch/portrait"))
    }

    func testSkippedActionButtonsDoNotCountTowardCap() {
        // The cap counts parsed buttons. A W004-skipped button never
        // renders, so it takes no slot.
        var json = combinedCapJSON(buttons: 20, actions: 0)
        json = json.replacingOccurrences(
            of: "\"actionButtons\": [  ]",
            with: """
                "actionButtons": [
                  { "action": "$nope1", "x": 0.5, "y": 0.5 },
                  { "action": "$nope2", "x": 0.5, "y": 0.5 }
                ]
                """)
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNotNil(result.manifest)
        XCTAssertNil(finding(result, code: "V015", path: "/touch/portrait"))
        XCTAssertEqual(result.findings.filter { $0.code == "W004" }.count, 2)
    }

    func testActionButtonRangeErrors() {
        let json = #"""
            { "version": 1, "touch": { "portrait": {
              "actionButtons": [
                { "action": "$pauseMenu", "x": 1.5, "y": 0.5, "size": 30, "opacity": 0.1 }
              ] } } }
            """#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(finding(result, code: "V011", path: "/touch/portrait/actionButtons/0/x"))
        XCTAssertNotNil(finding(result, code: "V012", path: "/touch/portrait/actionButtons/0/size"))
        XCTAssertNotNil(finding(result, code: "V012", path: "/touch/portrait/actionButtons/0/opacity"))
    }

    func testW004MissingActionField() {
        let json = #"""
            { "version": 1, "touch": { "portrait": {
              "actionButtons": [ { "x": 0.5, "y": 0.5 } ] } } }
            """#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertNotNil(result.manifest)
        let finding = finding(result, code: "W004", path: "/touch/portrait/actionButtons/0/action")
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.message.contains("(missing)") == true)
    }

    func testMissingCoordinateIsV011NotSilentDrop() {
        // A silently dropped button would vanish from disk on the next
        // load-modify-save cycle, so missing x/y must reject loudly.
        let buttonJSON = #"""
            { "version": 1, "touch": { "portrait": {
              "buttons": [ { "key": "KeyZ", "y": 0.5 } ] } } }
            """#
        let buttonResult = ControlsManifestLoader.parse(data: buttonJSON.data(using: .utf8)!)
        XCTAssertNil(buttonResult.manifest)
        XCTAssertNotNil(
            finding(buttonResult, code: "V011", path: "/touch/portrait/buttons/0/x"))

        let actionJSON = #"""
            { "version": 1, "touch": { "portrait": {
              "actionButtons": [ { "action": "$pauseMenu", "x": 0.5 } ] } } }
            """#
        let actionResult = ControlsManifestLoader.parse(data: actionJSON.data(using: .utf8)!)
        XCTAssertNil(actionResult.manifest)
        XCTAssertNotNil(
            finding(actionResult, code: "V011", path: "/touch/portrait/actionButtons/0/y"))
    }

    func testRenamedOldActionIDTakesUnknownPaths() {
        // Gate 2 ruling: no alias. The loader treats the old id as
        // unknown everywhere; only the app-side migration rewrites it.
        let controllerJSON = #"{ "version": 1, "controller": { "back": "$toggleOverlay" } }"#
        let controllerResult = ControlsManifestLoader.parse(
            data: controllerJSON.data(using: .utf8)!)
        XCTAssertNotNil(controllerResult.manifest)
        XCTAssertNotNil(finding(controllerResult, code: "W005", path: "/controller/back"))
        XCTAssertEqual(
            controllerResult.manifest?.bindings?.entries[.element("back")], .action("$toggleOverlay"))

        let touchJSON = #"""
            { "version": 1, "touch": { "portrait": {
              "actionButtons": [ { "action": "$toggleOverlay", "x": 0.5, "y": 0.5 } ] } } }
            """#
        let touchResult = ControlsManifestLoader.parse(data: touchJSON.data(using: .utf8)!)
        XCTAssertNotNil(touchResult.manifest)
        XCTAssertNotNil(
            finding(touchResult, code: "W004", path: "/touch/portrait/actionButtons/0/action"))
        XCTAssertEqual(touchResult.manifest?.touch?.portrait?.actionButtons, [])
    }

    func testMovementStyleParses() {
        let json = #"""
            { "version": 1, "touch": { "portrait": {
              "dpad": { "x": 0.25, "y": 0.75, "style": "stick" } } } }
            """#
        let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
        XCTAssertTrue(result.findings.isEmpty, "\(result.findings)")
        XCTAssertEqual(result.manifest?.touch?.portrait?.dpad?.style, .stick)

        let absent = #"{ "version": 1, "touch": { "portrait": { "dpad": { "x": 0.25, "y": 0.75 } } } }"#
        let absentResult = ControlsManifestLoader.parse(data: absent.data(using: .utf8)!)
        XCTAssertEqual(absentResult.manifest?.touch?.portrait?.dpad?.style, .dpad)
    }

    func testW006UnknownMovementStyleFallsBackToDPad() {
        // Unknown string AND wrong type both warn and fall back; a
        // future style value must never reject the file here.
        for value in [#""floating""#, "5"] {
            let json = """
                { "version": 1, "touch": { "portrait": {
                  "dpad": { "x": 0.25, "y": 0.75, "style": \(value) } } } }
                """
            let result = ControlsManifestLoader.parse(data: json.data(using: .utf8)!)
            XCTAssertNotNil(result.manifest, value)
            XCTAssertNotNil(
                finding(result, code: "W006", path: "/touch/portrait/dpad/style"), value)
            XCTAssertEqual(result.manifest?.touch?.portrait?.dpad?.style, .dpad, value)
        }
    }

    func testEmittedFindingCodesAreUniqueAndConsistent() {
        let codes = ControlsManifestLoader.emittedFindingCodes
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertTrue(codes.contains("V015"))
        XCTAssertTrue(codes.contains("W004"))
        XCTAssertTrue(codes.contains("W005"))
        XCTAssertTrue(codes.contains("W006"))
        XCTAssertFalse(codes.contains("V021"), "V021 is superseded by W005")
        for code in codes {
            XCTAssertTrue(
                code.hasPrefix("V") || code.hasPrefix("W")
                    || code.hasPrefix("K") || code.hasPrefix("J"),
                code
            )
        }
    }

    func testActionButtonsBranchIsIsolatedFromSiblings() {
        // Sibling-isolation check: parsing with and without the
        // `actionButtons` key yields identical results everywhere
        // else. NOTE: this runs the NEW parser on both inputs. The
        // real old-version compat claim rests on the old binary's
        // orientation-level `default: continue`, which no test here
        // can execute; that claim is verified by reading and stated
        // in docs/controls-format.md.
        let withActions = #"""
            { "version": 1, "touch": { "portrait": {
              "dpad": { "x": 0.14, "y": 0.74 },
              "buttons": [ { "key": "KeyZ", "x": 0.9, "y": 0.8 } ],
              "actionButtons": [ { "action": "$pauseMenu", "x": 0.5, "y": 0.5 } ]
              } }, "controller": { "y": "F5" } }
            """#
        let withoutActions = #"""
            { "version": 1, "touch": { "portrait": {
              "dpad": { "x": 0.14, "y": 0.74 },
              "buttons": [ { "key": "KeyZ", "x": 0.9, "y": 0.8 } ]
              } }, "controller": { "y": "F5" } }
            """#
        let a = ControlsManifestLoader.parse(data: withActions.data(using: .utf8)!)
        let b = ControlsManifestLoader.parse(data: withoutActions.data(using: .utf8)!)
        var stripped = a.manifest
        stripped?.touch?.portrait?.actionButtons = nil
        XCTAssertNotNil(a.manifest?.touch?.portrait?.actionButtons)
        XCTAssertEqual(stripped, b.manifest)
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
        XCTAssertEqual(result.manifest?.bindings?.entries[.element("a")], .key("Enter"))
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
        XCTAssertEqual(outcome?.result.manifest?.bindings?.entries[.element("a")], .key("Enter"))
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
        XCTAssertEqual(outcome?.result.manifest?.bindings?.entries[.element("a")], .key("Enter"))
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
        XCTAssertEqual(outcome?.result.manifest?.bindings?.entries[.element("a")], .key("Enter"))
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

import XCTest

@testable import GameProbe

final class ControlsManifestSerializerTests: XCTestCase {

    private func parseSerialized(_ data: Data) -> ControlsManifestLoader.Result {
        ControlsManifestLoader.parse(data: data)
    }

    private func sampleTouch() -> TouchSection {
        TouchSection(
            portrait: TouchLayout(
                dpad: DPadSpec(x: 0.13, y: 0.72, size: 140, opacity: 1),
                buttons: [
                    ButtonSpec(
                        label: "OK", key: "Enter",
                        x: 0.7, y: 0.67, size: 56, opacity: 1),
                    ButtonSpec(label: "Quit", key: "Escape", x: 0.88, y: 0.67, size: 56, opacity: 1),
                ]
            ),
            landscape: TouchLayout(
                dpad: DPadSpec(x: 0.1, y: 0.65, size: 140, opacity: 1),
                buttons: [
                    ButtonSpec(label: "OK", key: "Enter", x: 0.8, y: 0.59, size: 56, opacity: 1),
                ]
            )
        )
    }

    func testRoundTripZeroFindings() {
        let controller = BindingMap(entries: [
            "a": .key("Enter"),
            "b": .unbound,
            "start": .action("$pauseMenu"),
        ])
        guard let data = ControlsManifestSerializer.serialize(
            touch: sampleTouch(),
            bindings: controller
        ) else {
            XCTFail("expected data")
            return
        }

        let result = parseSerialized(data)
        XCTAssertNil(result.findings.first { $0.severity == .error })
        XCTAssertEqual(result.manifest?.version, 1)
        XCTAssertEqual(result.manifest?.bindings, controller)
        // The loader parses with the engine's json5pp, which builds
        // fractions with pow(10, -n). The parsed double lands within
        // an ulp of the written value, and WHICH ulp differs per
        // platform (Apple arm64 and glibc x86_64 disagree). An exact
        // Double comparison against the fixture is therefore not
        // portable. The contract that matters is at the wire level:
        // the parsed manifest must re-serialize to the exact same
        // bytes, because the serializer rounds to 6 decimals.
        let reserialized = ControlsManifestSerializer.serialize(
            touch: result.manifest?.touch,
            bindings: result.manifest?.bindings
        )
        XCTAssertEqual(reserialized, data)
    }

    func testKeySourcesRoundTrip() {
        let bindings = BindingMap(entries: [
            "a": .key("Enter"),
            "KeyJ": .element("a"),
            "KeyB": .key("Escape"),
            "Enter": .action("$pauseMenu"),
            "KeyM": .unbound,
        ])
        guard
            let data = ControlsManifestSerializer.serialize(touch: nil, bindings: bindings)
        else {
            XCTFail("expected data")
            return
        }
        let result = parseSerialized(data)
        XCTAssertNil(result.findings.first { $0.severity == .error })
        XCTAssertEqual(result.manifest?.bindings, bindings)

        let reserialized = ControlsManifestSerializer.serialize(
            touch: result.manifest?.touch,
            bindings: result.manifest?.bindings
        )
        XCTAssertEqual(reserialized, data)
    }

    func testElementsAreWrittenBeforeKeys() {
        let bindings = BindingMap(entries: ["KeyJ": .element("a"), "b": .key("Escape")])
        guard let data = ControlsManifestSerializer.serialize(touch: nil, bindings: bindings),
            let text = String(data: data, encoding: .utf8)
        else {
            XCTFail("expected data")
            return
        }
        guard let elementIndex = text.range(of: "\"b\""),
            let keyIndex = text.range(of: "\"KeyJ\"")
        else {
            XCTFail("expected both sources in \(text)")
            return
        }
        XCTAssertLessThan(elementIndex.lowerBound, keyIndex.lowerBound)
    }

    func testDeterministicOutput() {
        let touch = sampleTouch()
        let controller = BindingMap(entries: ["a": .key("KeyZ")])
        guard let first = ControlsManifestSerializer.serialize(touch: touch, bindings: controller),
            let second = ControlsManifestSerializer.serialize(touch: touch, bindings: controller)
        else {
            XCTFail("expected data")
            return
        }
        XCTAssertEqual(first, second)
    }

    func testUnmappableScancodeDropped() {
        var dropped: [(String, Int32)] = []
        let portrait = ControlsManifestSerializer.TouchOrientedInput(
            dpadX: 0.13,
            dpadY: 0.72,
            dpadSize: 140,
            dpadOpacity: 1,
            buttons: [
                ControlsManifestSerializer.TouchButtonInput(
                    label: "Ghost",
                    scancode: 9999,
                    x: 0.5,
                    y: 0.5,
                    size: 56,
                    opacity: 1
                ),
                ControlsManifestSerializer.TouchButtonInput(
                    label: "OK",
                    scancode: 40,
                    x: 0.7,
                    y: 0.67,
                    size: 56,
                    opacity: 1
                ),
            ]
        )
        let landscape = ControlsManifestSerializer.TouchOrientedInput(
            dpadX: 0.1,
            dpadY: 0.65,
            dpadSize: 140,
            dpadOpacity: 1,
            buttons: []
        )

        let touch = ControlsManifestSerializer.touchSection(
            portrait: portrait,
            landscape: landscape
        ) { label, scancode in
            dropped.append((label, scancode))
        }

        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped[0].0, "Ghost")
        XCTAssertEqual(dropped[0].1, 9999)
        XCTAssertEqual(touch.portrait?.buttons?.count, 1)
        XCTAssertEqual(touch.portrait?.buttons?.first?.key, "Enter")

        guard let data = ControlsManifestSerializer.serialize(touch: touch, bindings: nil) else {
            XCTFail("expected data")
            return
        }
        let result = parseSerialized(data)
        XCTAssertTrue(result.findings.filter { $0.severity == .error }.isEmpty)
    }

    func testClampingProducesValidOutput() {
        let portrait = ControlsManifestSerializer.TouchOrientedInput(
            dpadX: -0.5,
            dpadY: 2.0,
            dpadSize: 50,
            dpadOpacity: 0.05,
            buttons: [
                ControlsManifestSerializer.TouchButtonInput(
                    label: "Wide",
                    scancode: 40,
                    x: 1.5,
                    y: -1,
                    size: 10,
                    opacity: 2
                ),
            ]
        )
        let landscape = ControlsManifestSerializer.TouchOrientedInput(
            dpadX: 0.1,
            dpadY: 0.65,
            dpadSize: 500,
            dpadOpacity: 1,
            buttons: []
        )

        let touch = ControlsManifestSerializer.touchSection(
            portrait: portrait,
            landscape: landscape
        )
        guard let data = ControlsManifestSerializer.serialize(touch: touch, bindings: nil) else {
            XCTFail("expected data")
            return
        }

        let result = parseSerialized(data)
        XCTAssertTrue(result.findings.filter { $0.severity == .error }.isEmpty)
        XCTAssertEqual(result.manifest?.touch?.portrait?.dpad?.x, 0)
        XCTAssertEqual(result.manifest?.touch?.portrait?.dpad?.y, 1)
        XCTAssertEqual(result.manifest?.touch?.portrait?.dpad?.size, 100)
        XCTAssertEqual(result.manifest?.touch?.portrait?.dpad?.opacity, 0.2)
        XCTAssertEqual(result.manifest?.touch?.portrait?.buttons?.first?.size, 40)
        XCTAssertEqual(result.manifest?.touch?.portrait?.buttons?.first?.opacity, 1)
        XCTAssertEqual(result.manifest?.touch?.landscape?.dpad?.size, 200)
    }

    func testBindingsOnlyOmitTouch() {
        let controller = BindingMap(entries: ["a": .key("Enter")])
        guard let data = ControlsManifestSerializer.serialize(touch: nil, bindings: controller) else {
            XCTFail("expected data")
            return
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("\"touch\""))
        XCTAssertTrue(text.contains("\"bindings\""))

        let result = parseSerialized(data)
        XCTAssertNil(result.manifest?.touch)
        XCTAssertEqual(result.manifest?.bindings, controller)
        XCTAssertTrue(result.findings.filter { $0.severity == .error }.isEmpty)
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ControlsManifestSerializer.serialize(touch: nil, bindings: nil))
        XCTAssertNil(
            ControlsManifestSerializer.serialize(
                touch: nil,
                bindings: BindingMap(entries: [:])
            ))
    }

    func testTrailingNewline() {
        guard let data = ControlsManifestSerializer.serialize(touch: sampleTouch(), bindings: nil) else {
            XCTFail("expected data")
            return
        }
        XCTAssertEqual(data.last, UInt8(ascii: "\n"))
    }

    func testActionButtonsRoundTrip() {
        var touch = sampleTouch()
        touch.portrait?.actionButtons = [
            ActionButtonSpec(action: "$toggleFastForward", x: 0.75, y: 0.25, size: 56, opacity: 0.5),
            ActionButtonSpec(action: "$pauseMenu", x: 0.5, y: 0.25, size: 44, opacity: 1),
        ]
        guard let data = ControlsManifestSerializer.serialize(touch: touch, bindings: nil) else {
            XCTFail("expected data")
            return
        }

        let result = parseSerialized(data)
        XCTAssertNil(result.findings.first { $0.severity == .error })
        XCTAssertEqual(result.manifest?.touch?.portrait?.actionButtons?.count, 2)
        XCTAssertEqual(
            result.manifest?.touch?.portrait?.actionButtons?.first?.action,
            "$toggleFastForward"
        )
        XCTAssertNil(result.manifest?.touch?.landscape?.actionButtons)

        // Wire-level stability: parse and re-serialize must reproduce
        // the exact bytes.
        let reserialized = ControlsManifestSerializer.serialize(
            touch: result.manifest?.touch,
            bindings: nil
        )
        XCTAssertEqual(reserialized, data)
    }

    func testUnknownControllerActionRoundTripsByteStable() {
        // W005 keeps unknown action entries. Saving the map back must
        // not strip or rewrite them.
        let controller = BindingMap(entries: [
            "start": .action("$notAnAction"),
            "a": .key("Enter"),
        ])
        guard let data = ControlsManifestSerializer.serialize(touch: nil, bindings: controller)
        else {
            XCTFail("expected data")
            return
        }

        let result = parseSerialized(data)
        XCTAssertNil(result.findings.first { $0.severity == .error })
        XCTAssertEqual(result.findings.first { $0.code == "W005" }?.path, "/bindings/start")
        XCTAssertEqual(result.manifest?.bindings?.entries["start"], .action("$notAnAction"))

        let reserialized = ControlsManifestSerializer.serialize(
            touch: nil,
            bindings: result.manifest?.bindings
        )
        XCTAssertEqual(reserialized, data)
    }

    func testEmptyActionButtonsListRoundTrips() {
        // Pinned behavior: `[]` and an omitted key differ. nil means
        // "inherit the game-shipped action buttons"; [] means "none"
        // (the user deleted them all). Collapsing [] to an omitted
        // key would resurrect deleted buttons on the next load.
        var touch = sampleTouch()
        touch.portrait?.actionButtons = []
        guard let data = ControlsManifestSerializer.serialize(touch: touch, bindings: nil)
        else {
            XCTFail("expected data")
            return
        }
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"actionButtons\": ["))
        let result = parseSerialized(data)
        XCTAssertEqual(result.manifest?.touch?.portrait?.actionButtons, [])
        // The untouched orientation keeps no key at all.
        XCTAssertNil(result.manifest?.touch?.landscape?.actionButtons)
    }

    func testGoldenOutputBytes() {
        // Byte-level pin for the wire format. A whitespace or
        // ordering change here rewrites every user file on its next
        // save; change this expectation only on purpose.
        let touch = TouchSection(
            portrait: TouchLayout(
                dpad: DPadSpec(x: 0.25, y: 0.75, size: 140, opacity: 1),
                buttons: [
                    ButtonSpec(label: "OK", key: "Enter", x: 0.75, y: 0.5, size: 56, opacity: 1)
                ],
                actionButtons: [
                    ActionButtonSpec(action: "$pauseMenu", x: 0.5, y: 0.25, size: 44, opacity: 0.5)
                ]
            )
        )
        let controller = BindingMap(entries: [
            "a": .key("Enter"),
            "back": .action("$toggleTouchControls"),
            "start": .unbound,
        ])
        let data = ControlsManifestSerializer.serialize(touch: touch, bindings: controller)
        // Line array because two lines carry trailing spaces (the
        // array-item separator lines), which a multiline literal
        // cannot express reliably.
        let expected = [
            "{",
            "  \"version\": 1",
            "  ,\"touch\": {",
            "    \"portrait\": {",
            "      \"dpad\": {",
            "        \"x\": 0.25",
            "        ,\"y\": 0.75",
            "        ,\"size\": 140",
            "        ,\"opacity\": 1",
            "      }",
            "      ,\"buttons\": [",
            "        ",
            "          {",
            "            \"label\": \"OK\"",
            "            ,\"key\": \"Enter\"",
            "            ,\"x\": 0.75",
            "            ,\"y\": 0.5",
            "            ,\"size\": 56",
            "            ,\"opacity\": 1",
            "          }",
            "      ]",
            "      ,\"actionButtons\": [",
            "        ",
            "          {",
            "            \"action\": \"$pauseMenu\"",
            "            ,\"x\": 0.5",
            "            ,\"y\": 0.25",
            "            ,\"size\": 44",
            "            ,\"opacity\": 0.5",
            "          }",
            "      ]",
            "    }",
            "  }",
            "  ,\"bindings\": {",
            "    \"a\": \"Enter\"",
            "    ,\"back\": \"$toggleTouchControls\"",
            "    ,\"start\": null",
            "  }",
            "}",
            "",
        ].joined(separator: "\n")
        XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), expected)
    }

    func testStickStyleRoundTrips() {
        var touch = sampleTouch()
        touch.portrait?.dpad?.style = .stick
        guard let data = ControlsManifestSerializer.serialize(touch: touch, bindings: nil)
        else {
            XCTFail("expected data")
            return
        }
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"style\": \"stick\""))
        let result = parseSerialized(data)
        XCTAssertNil(result.findings.first { $0.severity == .error })
        XCTAssertEqual(result.manifest?.touch?.portrait?.dpad?.style, .stick)
        // The untouched orientation carries no style field on disk,
        // so every existing file serializes byte-identically.
        XCTAssertEqual(result.manifest?.touch?.landscape?.dpad?.style, .dpad)
        let reserialized = ControlsManifestSerializer.serialize(
            touch: result.manifest?.touch, bindings: nil)
        XCTAssertEqual(reserialized, data)
    }

    func testDPadStyleInputOmitsField() {
        let input = ControlsManifestSerializer.TouchOrientedInput(
            dpadX: 0.25, dpadY: 0.75, dpadSize: 140, dpadOpacity: 1,
            dpadStyle: .dpad, buttons: [])
        let section = ControlsManifestSerializer.touchSection(portrait: input, landscape: input)
        XCTAssertEqual(section.portrait?.dpad?.style, .dpad)

        let stick = ControlsManifestSerializer.TouchOrientedInput(
            dpadX: 0.25, dpadY: 0.75, dpadSize: 140, dpadOpacity: 1,
            dpadStyle: .stick, buttons: [])
        let stickSection = ControlsManifestSerializer.touchSection(portrait: stick, landscape: stick)
        XCTAssertEqual(stickSection.portrait?.dpad?.style, .stick)
    }

    func testTouchInputConvertsActionButtons() {
        let input = ControlsManifestSerializer.TouchOrientedInput(
            dpadX: 0.13, dpadY: 0.72, dpadSize: 140, dpadOpacity: 1,
            buttons: [],
            actionButtons: [
                ControlsManifestSerializer.TouchActionButtonInput(
                    action: "$toggleCheats", x: 1.5, y: -0.25, size: 500, opacity: 0)
            ]
        )
        let section = ControlsManifestSerializer.touchSection(portrait: input, landscape: input)
        // Writer-side clamping keeps the round trip valid.
        let button = section.portrait?.actionButtons?.first
        XCTAssertEqual(button?.action, "$toggleCheats")
        XCTAssertEqual(button?.x, 1.0)
        XCTAssertEqual(button?.y, 0.0)
        XCTAssertEqual(button?.size, 100)
        XCTAssertEqual(button?.opacity, 0.2)
    }
}

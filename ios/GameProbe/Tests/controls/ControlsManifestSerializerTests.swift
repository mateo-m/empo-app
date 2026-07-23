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
        let controller = ControllerMap(entries: [
            "a": .key("Enter"),
            "b": .unbound,
            "start": .action("$pauseMenu"),
        ])
        guard let data = ControlsManifestSerializer.serialize(
            touch: sampleTouch(),
            controller: controller
        ) else {
            XCTFail("expected data")
            return
        }

        let result = parseSerialized(data)
        XCTAssertNil(result.findings.first { $0.severity == .error })
        XCTAssertEqual(result.manifest?.version, 1)
        XCTAssertEqual(result.manifest?.controller, controller)
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
            controller: result.manifest?.controller
        )
        XCTAssertEqual(reserialized, data)
    }

    func testDeterministicOutput() {
        let touch = sampleTouch()
        let controller = ControllerMap(entries: ["a": .key("KeyZ")])
        guard let first = ControlsManifestSerializer.serialize(touch: touch, controller: controller),
            let second = ControlsManifestSerializer.serialize(touch: touch, controller: controller)
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

        guard let data = ControlsManifestSerializer.serialize(touch: touch, controller: nil) else {
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
        guard let data = ControlsManifestSerializer.serialize(touch: touch, controller: nil) else {
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

    func testControllerOnlyOmitsTouch() {
        let controller = ControllerMap(entries: ["a": .key("Enter")])
        guard let data = ControlsManifestSerializer.serialize(touch: nil, controller: controller) else {
            XCTFail("expected data")
            return
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("\"touch\""))
        XCTAssertTrue(text.contains("\"controller\""))

        let result = parseSerialized(data)
        XCTAssertNil(result.manifest?.touch)
        XCTAssertEqual(result.manifest?.controller, controller)
        XCTAssertTrue(result.findings.filter { $0.severity == .error }.isEmpty)
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ControlsManifestSerializer.serialize(touch: nil, controller: nil))
        XCTAssertNil(
            ControlsManifestSerializer.serialize(
                touch: nil,
                controller: ControllerMap(entries: [:])
            ))
    }

    func testTrailingNewline() {
        guard let data = ControlsManifestSerializer.serialize(touch: sampleTouch(), controller: nil) else {
            XCTFail("expected data")
            return
        }
        XCTAssertEqual(data.last, UInt8(ascii: "\n"))
    }
}

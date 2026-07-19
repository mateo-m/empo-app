import XCTest

@testable import GameProbe

final class ControllerMapResolverTests: XCTestCase {

    func testEmptyLayersReturnsBuiltinMap() {
        let map = ControllerMapResolver.resolve(layers: [])
        XCTAssertEqual(map["a"], .key("Enter"))
        XCTAssertEqual(map["b"], .key("Escape"))
        XCTAssertEqual(map["x"], .key("ShiftLeft"))
        XCTAssertEqual(map["y"], .key("KeyA"))
        XCTAssertEqual(map["start"], .action("$pauseMenu"))
        XCTAssertNil(map["guide"])
    }

    func testManifestOverridesGlobalUserOverride() {
        let global = ControllerMap(entries: ["y": .key("KeyX")])
        let manifest = ControllerMap(entries: ["y": .key("F5")])
        let map = ControllerMapResolver.resolve(layers: [global, manifest])
        XCTAssertEqual(map["y"], .key("F5"))
    }

    func testPerGameUserBeatsManifest() {
        let manifest = ControllerMap(entries: ["y": .key("F5")])
        let perGame = ControllerMap(entries: ["y": .key("KeyB")])
        let map = ControllerMapResolver.resolve(layers: [manifest, perGame])
        XCTAssertEqual(map["y"], .key("KeyB"))
    }

    func testUnboundAtHigherLayerRemovesBuiltinBinding() {
        let manifest = ControllerMap(entries: ["y": .unbound])
        let map = ControllerMapResolver.resolve(layers: [manifest])
        XCTAssertNil(map["y"])
    }

    func testRebindAfterUnbindAtHigherLayer() {
        let manifest = ControllerMap(entries: ["y": .unbound])
        let perGame = ControllerMap(entries: ["y": .key("KeyB")])
        let map = ControllerMapResolver.resolve(layers: [manifest, perGame])
        XCTAssertEqual(map["y"], .key("KeyB"))
    }

    func testResolvedRuntimeMapResolvesScancodes() {
        let map = ControllerMapResolver.resolvedRuntimeMap(layers: [])
        XCTAssertEqual(map["a"], .key(40))
        XCTAssertEqual(map["start"], .action("$pauseMenu"))
    }
}

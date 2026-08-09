import XCTest

@testable import GameProbe

final class BindingResolverTests: XCTestCase {

    func testEmptyLayersReturnsBuiltinMap() {
        let map = BindingResolver.resolve(layers: [])
        XCTAssertEqual(map[.element("a")], .key("Enter"))
        XCTAssertEqual(map[.element("b")], .key("Escape"))
        XCTAssertEqual(map[.element("x")], .key("ShiftLeft"))
        XCTAssertEqual(map[.element("y")], .key("KeyA"))
        XCTAssertEqual(map[.element("start")], .action("$pauseMenu"))
        XCTAssertNil(map[.element("guide")])
    }

    func testManifestOverridesGlobalUserOverride() {
        let global = BindingMap(entries: [.element("y"): .key("KeyX")])
        let manifest = BindingMap(entries: [.element("y"): .key("F5")])
        let map = BindingResolver.resolve(layers: [global, manifest])
        XCTAssertEqual(map[.element("y")], .key("F5"))
    }

    func testPerGameUserBeatsManifest() {
        let manifest = BindingMap(entries: [.element("y"): .key("F5")])
        let perGame = BindingMap(entries: [.element("y"): .key("KeyB")])
        let map = BindingResolver.resolve(layers: [manifest, perGame])
        XCTAssertEqual(map[.element("y")], .key("KeyB"))
    }

    func testUnboundAtHigherLayerRemovesBuiltinBinding() {
        let manifest = BindingMap(entries: [.element("y"): .unbound])
        let map = BindingResolver.resolve(layers: [manifest])
        XCTAssertNil(map[.element("y")])
    }

    func testRebindAfterUnbindAtHigherLayer() {
        let manifest = BindingMap(entries: [.element("y"): .unbound])
        let perGame = BindingMap(entries: [.element("y"): .key("KeyB")])
        let map = BindingResolver.resolve(layers: [manifest, perGame])
        XCTAssertEqual(map[.element("y")], .key("KeyB"))
    }

    func testRuntimeElementsResolveScancodes() {
        let runtime = BindingResolver.resolveRuntime()
        XCTAssertEqual(runtime.elements["a"], .key(40))
        XCTAssertEqual(runtime.elements["start"], .action("$pauseMenu"))
    }

    // MARK: - Key sources

    func testUnmappedKeysStayOutOfTheKeyMap() {
        // An absent key passes through to the game, so a plain
        // keyboard keeps typing.
        XCTAssertTrue(BindingResolver.resolveRuntime().keys.isEmpty)
    }

    func testKeyBoundToElementInheritsTheElementBinding() {
        let layer = BindingMap(entries: [.key("KeyJ"): .element("a")])
        let runtime = BindingResolver.resolveRuntime(layers: [layer])
        XCTAssertEqual(runtime.keys[13], .key(40))  // KeyJ -> a -> Enter
    }

    func testKeyBoundToElementFollowsTheElementOverride() {
        let layers = [
            BindingMap(entries: [.key("KeyJ"): .element("a")]),
            BindingMap(entries: [.element("a"): .key("KeyZ")]),
        ]
        let runtime = BindingResolver.resolveRuntime(layers: layers)
        XCTAssertEqual(runtime.keys[13], .key(29))  // KeyJ -> a -> KeyZ
    }

    func testKeyBoundToActionElement() {
        let layer = BindingMap(entries: [.key("Escape"): .element("start")])
        XCTAssertEqual(
            BindingResolver.resolveRuntime(layers: [layer]).keys[41], .action("$pauseMenu"))
    }

    func testKeyBoundToUnboundElementGoesSilent() {
        // The player asked for a pad button. If that button does
        // nothing, the key must not fall back to typing itself.
        let layers = [
            BindingMap(entries: [.key("KeyJ"): .element("y")]),
            BindingMap(entries: [.element("y"): .unbound]),
        ]
        XCTAssertEqual(BindingResolver.resolveRuntime(layers: layers).keys[13], .unbound)
    }

    func testUnboundKeySurvivesTheMerge() {
        let layer = BindingMap(entries: [.key("KeyM"): .unbound])
        XCTAssertEqual(BindingResolver.resolveRuntime(layers: [layer]).keys[16], .unbound)
    }

    func testKeyAndElementSourcesResolveSideBySide() {
        let layer = BindingMap(entries: [
            .key("KeyB"): .key("Escape"),
            .element("y"): .key("KeyX"),
        ])
        let runtime = BindingResolver.resolveRuntime(layers: [layer])
        XCTAssertEqual(runtime.keys[5], .key(41))
        XCTAssertEqual(runtime.elements["y"], .key(27))
        // A key source must never leak into the element map.
        XCTAssertNil(runtime.elements["KeyB"])
    }

    func testSwappedKeysResolveIndependently() {
        let layer = BindingMap(entries: [.key("KeyZ"): .key("KeyX"), .key("KeyX"): .key("KeyZ")])
        let runtime = BindingResolver.resolveRuntime(layers: [layer])
        XCTAssertEqual(runtime.keys[29], .key(27))
        XCTAssertEqual(runtime.keys[27], .key(29))
    }
}

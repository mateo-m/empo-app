import XCTest

@testable import GameProbe

final class BindingResolverTests: XCTestCase {

    func testEmptyLayersReturnsBuiltinMap() {
        let map = BindingResolver.resolve(layers: [])
        XCTAssertEqual(map["a"], .key("Enter"))
        XCTAssertEqual(map["b"], .key("Escape"))
        XCTAssertEqual(map["x"], .key("ShiftLeft"))
        XCTAssertEqual(map["y"], .key("KeyA"))
        XCTAssertEqual(map["start"], .action("$pauseMenu"))
        XCTAssertNil(map["guide"])
    }

    func testManifestOverridesGlobalUserOverride() {
        let global = BindingMap(entries: ["y": .key("KeyX")])
        let manifest = BindingMap(entries: ["y": .key("F5")])
        let map = BindingResolver.resolve(layers: [global, manifest])
        XCTAssertEqual(map["y"], .key("F5"))
    }

    func testPerGameUserBeatsManifest() {
        let manifest = BindingMap(entries: ["y": .key("F5")])
        let perGame = BindingMap(entries: ["y": .key("KeyB")])
        let map = BindingResolver.resolve(layers: [manifest, perGame])
        XCTAssertEqual(map["y"], .key("KeyB"))
    }

    func testUnboundAtHigherLayerRemovesBuiltinBinding() {
        let manifest = BindingMap(entries: ["y": .unbound])
        let map = BindingResolver.resolve(layers: [manifest])
        XCTAssertNil(map["y"])
    }

    func testRebindAfterUnbindAtHigherLayer() {
        let manifest = BindingMap(entries: ["y": .unbound])
        let perGame = BindingMap(entries: ["y": .key("KeyB")])
        let map = BindingResolver.resolve(layers: [manifest, perGame])
        XCTAssertEqual(map["y"], .key("KeyB"))
    }

    func testResolvedRuntimeMapResolvesScancodes() {
        let map = BindingResolver.resolvedRuntimeMap(layers: [])
        XCTAssertEqual(map["a"], .key(40))
        XCTAssertEqual(map["start"], .action("$pauseMenu"))
    }

    // MARK: - Key sources

    func testUnmappedKeysStayOutOfTheKeyMap() {
        // An absent key passes through to the game, so a plain
        // keyboard keeps typing.
        XCTAssertTrue(BindingResolver.resolvedKeyMap(layers: []).isEmpty)
    }

    func testKeyBoundToElementInheritsTheElementBinding() {
        let layer = BindingMap(entries: ["KeyJ": .element("a")])
        let map = BindingResolver.resolvedKeyMap(layers: [layer])
        XCTAssertEqual(map[13], .key(40))  // KeyJ -> a -> Enter
    }

    func testKeyBoundToElementFollowsTheElementOverride() {
        let layers = [
            BindingMap(entries: ["KeyJ": .element("a")]),
            BindingMap(entries: ["a": .key("KeyZ")]),
        ]
        let map = BindingResolver.resolvedKeyMap(layers: layers)
        XCTAssertEqual(map[13], .key(29))  // KeyJ -> a -> KeyZ
    }

    func testKeyBoundToActionElement() {
        let layer = BindingMap(entries: ["Escape": .element("start")])
        let map = BindingResolver.resolvedKeyMap(layers: [layer])
        XCTAssertEqual(map[41], .action("$pauseMenu"))
    }

    func testKeyBoundToUnboundElementGoesSilent() {
        // The player asked for a pad button. If that button does
        // nothing, the key must not fall back to typing itself.
        let layers = [
            BindingMap(entries: ["KeyJ": .element("y")]),
            BindingMap(entries: ["y": .unbound]),
        ]
        XCTAssertEqual(BindingResolver.resolvedKeyMap(layers: layers)[13], .unbound)
    }

    func testUnboundKeySurvivesTheMerge() {
        let layer = BindingMap(entries: ["KeyM": .unbound])
        XCTAssertEqual(BindingResolver.resolvedKeyMap(layers: [layer])[16], .unbound)
    }

    func testKeyAndElementSourcesResolveSideBySide() {
        let layer = BindingMap(entries: ["KeyB": .key("Escape"), "y": .key("KeyX")])
        let layers = [layer]
        XCTAssertEqual(BindingResolver.resolvedKeyMap(layers: layers)[5], .key(41))
        XCTAssertEqual(BindingResolver.resolvedRuntimeMap(layers: layers)["y"], .key(27))
        // A key source must never leak into the element map.
        XCTAssertNil(BindingResolver.resolvedRuntimeMap(layers: layers)["KeyB"])
    }

    func testSwappedKeysResolveIndependently() {
        let layer = BindingMap(entries: ["KeyZ": .key("KeyX"), "KeyX": .key("KeyZ")])
        let map = BindingResolver.resolvedKeyMap(layers: [layer])
        XCTAssertEqual(map[29], .key(27))
        XCTAssertEqual(map[27], .key(29))
    }
}

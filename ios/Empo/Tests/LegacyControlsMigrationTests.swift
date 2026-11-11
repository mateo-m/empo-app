// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

@MainActor
final class LegacyControlsMigrationTests: XCTestCase {
    private var container: GameContainer!
    private var layoutKey: String { DefaultsKey.controlsLayout(gameID: container.id) }
    private var mapKey: String { DefaultsKey.controllerMap(gameID: container.id) }

    override func setUp() async throws {
        container = GameContainer(folderName: "legacy-controls-\(UUID().uuidString)")
        try container.ensureSubdirs()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: layoutKey)
        UserDefaults.standard.removeObject(forKey: mapKey)
        try? FileManager.default.removeItem(at: container.url)
    }

    func testALayoutThatDoesNotReadStaysWhenTheBindingsMove() throws {
        let damaged = Data("{ this is not a layout".utf8)
        UserDefaults.standard.set(damaged, forKey: layoutKey)
        let map = BindingMap(entries: [.element("a"): .unbound])
        let mapData = try JSONSerialization.data(withJSONObject: BindingMapCoder.encode(map))
        UserDefaults.standard.set(mapData, forKey: mapKey)

        LegacyControlsMigration.run(container: container, keys: [])

        XCTAssertEqual(UserControlsFile.acceptedManifest(in: container)?.bindings, map)
        XCTAssertNil(UserDefaults.standard.data(forKey: mapKey))
        XCTAssertEqual(UserDefaults.standard.data(forKey: layoutKey), damaged)
    }
}

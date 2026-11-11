// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

@MainActor
final class LegacyControlsMigrationTests: XCTestCase {

    private var container: GameContainer!
    private var layoutKey: String { DefaultsKey.controlsLayout(gameID: container.id) }
    private var mapKey: String { DefaultsKey.controllerMap(gameID: container.id) }
    private let unreadable = Data("{\"buttons\":".utf8)
    private let layout = Data(
        """
        {"portrait":{"dpad":{"rx":0.2,"ry":0.7,"size":120},"buttons":[]},
         "landscape":{"dpad":{"rx":0.1,"ry":0.6,"size":110},"buttons":[]}}
        """.utf8)

    override func setUp() async throws {
        try await super.setUp()
        container = GameContainer(folderName: "legacy-controls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container.empoStateURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: layoutKey)
        UserDefaults.standard.removeObject(forKey: mapKey)
        try? FileManager.default.removeItem(at: container.url)
        try await super.tearDown()
    }

    func testAnUnreadableSourceKeepsItsBytesWhenTheOtherSourceMoves() {
        UserDefaults.standard.set(layout, forKey: layoutKey)
        UserDefaults.standard.set(unreadable, forKey: mapKey)

        LegacyControlsMigration.run(container: container, keys: [])

        XCTAssertTrue(UserControlsFile.exists(in: container))
        XCTAssertNil(UserDefaults.standard.data(forKey: layoutKey))
        XCTAssertEqual(UserDefaults.standard.data(forKey: mapKey), unreadable)
    }

    func testAnUnreadableLayoutKeepsItsBytesWhenTheButtonsMove() {
        UserDefaults.standard.set(unreadable, forKey: layoutKey)
        UserDefaults.standard.set(Data("{\"a\":\"Enter\"}".utf8), forKey: mapKey)

        LegacyControlsMigration.run(container: container, keys: [])

        XCTAssertTrue(UserControlsFile.exists(in: container))
        XCTAssertEqual(UserDefaults.standard.data(forKey: layoutKey), unreadable)
        XCTAssertNil(UserDefaults.standard.data(forKey: mapKey))
    }

    func testAMovedLayoutLeavesNoLegacyKey() {
        UserDefaults.standard.set(layout, forKey: layoutKey)

        LegacyControlsMigration.run(container: container, keys: [])

        XCTAssertTrue(UserControlsFile.exists(in: container))
        XCTAssertNil(UserDefaults.standard.data(forKey: layoutKey))
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

@MainActor
final class SavedBindingsTests: XCTestCase {
    private var container: GameContainer!

    override func setUp() async throws {
        container = GameContainer(folderName: "saved-bindings-\(UUID().uuidString)")
        try container.ensureSubdirs()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: container.url)
    }

    private func saved(after entries: [BindingSource: BindingMap.Target]) -> BindingsCatalog.SavedBindings {
        BindingStore.savePerGame(container: container, map: BindingMap(entries: entries))
        return BindingsCatalog.SavedBindings(scope: .thisGame, container: container, manifest: nil)
    }

    func testButtonSetToDoNothingShowsDoNothing() {
        let saved = saved(after: [.element("a"): .unbound])

        XCTAssertEqual(saved.target(for: .element("a")), .unbound)
        XCTAssertEqual(saved.provenance(for: .element("a")), .userOverride)
    }

    func testActionFromANewerEmpoStaysUnsupported() {
        let saved = saved(after: [.element("a"): .action("$fromANewerEmpo")])
        let target = saved.target(for: .element("a"))

        XCTAssertEqual(target, .action("$fromANewerEmpo"))
        XCTAssertEqual(BindingsCatalog.displayName(for: target), "Not supported in this version of Empo")
    }
}

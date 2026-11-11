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

    private func saved(
        after entries: [BindingSource: BindingMap.Target]
    ) throws -> BindingsCatalog.SavedBindings {
        try BindingStore.savePerGame(container: container, map: BindingMap(entries: entries))
        return BindingsCatalog.SavedBindings(scope: .thisGame(container), manifest: nil)
    }

    func testButtonSetToDoNothingShowsDoNothing() throws {
        let saved = try saved(after: [.element("a"): .unbound])

        XCTAssertEqual(saved.target(for: .element("a")), .unbound)
        XCTAssertEqual(saved.provenance(for: .element("a")), .userOverride)
    }

    func testActionFromANewerEmpoStaysUnsupported() throws {
        let saved = try saved(after: [.element("a"): .action("$fromANewerEmpo")])
        let target = saved.target(for: .element("a"))

        XCTAssertEqual(target, .action("$fromANewerEmpo"))
        XCTAssertEqual(BindingsCatalog.displayName(for: target), "Not supported in this version of Empo")
    }

    private func writeControlsFile(_ text: String) throws -> Data {
        let data = Data(text.utf8)
        _ = container.ensureEmpoStateDirectory()
        try data.write(to: container.userControlsURL)
        return data
    }

    private func assertRefused(
        _ expected: UserControlsFile.SaveRefusal,
        keeping data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let map = BindingMap(entries: [.element("a"): .key("Enter")])
        XCTAssertThrowsError(
            try BindingStore.savePerGame(container: container, map: map), file: file, line: line
        ) {
            XCTAssertEqual($0 as? UserControlsFile.SaveRefusal, expected, file: file, line: line)
        }
        XCTAssertThrowsError(try BindingStore.deletePerGame(container: container), file: file, line: line) {
            XCTAssertEqual($0 as? UserControlsFile.SaveRefusal, expected, file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: container.userControlsURL), data, file: file, line: line)
    }

    func testASaveKeepsAControlsFileThatHasErrors() throws {
        let data = try writeControlsFile(#"{ "version": 1, "touch": { "buttons": [ "#)

        try assertRefused(.fileHasErrors, keeping: data)
    }

    func testASaveKeepsAControlsFileFromANewerEmpo() throws {
        let data = try writeControlsFile(#"{ "version": 2, "touch": { "buttons": [] } }"#)

        try assertRefused(.fileNeedsNewerEmpo, keeping: data)
    }
}

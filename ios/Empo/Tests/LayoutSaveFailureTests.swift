// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

/// A save at Done that cannot write keeps edit mode and every edit, so
/// Done can run again.
@MainActor
final class LayoutSaveFailureTests: XCTestCase {

    private var game: GameContainer!
    private var lockedFolders: [URL] = []
    private var layout: ControlsLayout { ControlsLayout.shared }

    override func setUp() async throws {
        game = GameContainer(folderName: "save-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: game.gameURL, withIntermediateDirectories: true)
        try Data("# game".utf8).write(to: game.gameURL.appendingPathComponent("Game.rb"))
        layout.switchGame(id: game.id, container: game, title: "Save Failure \(UUID().uuidString)")
    }

    override func tearDown() async throws {
        for folder in lockedFolders { unlock(folder) }
        let pinned: String? =
            if case .pinnedProfile(let name) = layout.provenance { name } else { nil }
        // switchGame saves the open edit session, so it runs before the delete.
        layout.switchGame(id: nil, container: nil)
        if let pinned {
            XCTAssertNoThrow(try LayoutProfilesManager.store.deleteProfile(pinned))
        }
        try? FileManager.default.removeItem(at: game.url)
    }

    private func lock(_ folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        lockedFolders.append(folder)
    }

    private func unlock(_ folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }

    func testAFailedNewProfileKeepsTheEditSessionAndTheMove() throws {
        layout.beginEditSession()
        let button = try XCTUnwrap(layout.buttons.first)
        let moved = CGPoint(x: 0.3, y: 0.6)
        layout.updateButton(id: button.id, relativeCenter: moved)

        try lock(LayoutProfilesManager.profilesRootURL)
        XCTAssertThrowsError(try layout.save())
        XCTAssertTrue(layout.editSessionActive)
        XCTAssertEqual(layout.buttons.first { $0.id == button.id }?.relativeCenter, moved)
        if case .pinnedProfile = layout.provenance {
            XCTFail("A failed save must not pin a profile.")
        }

        unlock(LayoutProfilesManager.profilesRootURL)
        try layout.save()
        guard case .pinnedProfile(let name) = layout.provenance else {
            return XCTFail("The second Done did not create the profile.")
        }
        XCTAssertNotNil(LayoutProfilesManager.store.readProfile(name)?.touch)
    }

    func testAFailedScreenSaveKeepsTheScreenPosition() throws {
        layout.beginEditSession()
        let button = try XCTUnwrap(layout.buttons.first)
        layout.updateButton(id: button.id, relativeCenter: CGPoint(x: 0.3, y: 0.6))
        try layout.save()
        guard case .pinnedProfile(let name) = layout.provenance else {
            return XCTFail("The first Done did not create the profile.")
        }

        let placement = ScreenPlacement.region(ScreenRegion(x: 0.1, y: 0.1, w: 0.5, h: 0.4))
        layout.recordScreenEdit(placement)
        try lock(LayoutProfilesManager.store.profileURL(name))
        XCTAssertThrowsError(try layout.save())
        XCTAssertEqual(layout.pendingScreenEdit, .set(placement))

        unlock(LayoutProfilesManager.store.profileURL(name))
        try layout.save()
        XCTAssertNil(layout.pendingScreenEdit)
        let screen = LayoutProfilesManager.store.readScreen(name)
        let saved = layout.currentOrientation == .portrait ? screen?.portrait : screen?.landscape
        XCTAssertEqual(saved, placement)
    }
}

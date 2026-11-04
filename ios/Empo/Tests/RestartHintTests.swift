// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

@MainActor
final class RestartHintTests: XCTestCase {
    private var container: GameContainer!

    override func setUp() async throws {
        container = GameContainer(folderName: "restart-hint-\(UUID().uuidString)")
        try container.ensureSubdirs()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: container.url)
    }

    func testHintStaysWhenTheSettingsOpenAgain() throws {
        let game = GameEntry(id: "game", container: container, title: "Game", artworkPath: nil)
        let launched = LaunchedSettings(settings: GameSettings.load(from: container.empoStateURL), core: nil)

        let first = GameSettingsModel(game: game)
        XCTAssertNil(first.restartHint(since: launched))
        first.settings.smoothScaling = true
        first.save()

        let reopened = try XCTUnwrap(GameSettingsModel(game: game).restartHint(since: launched))
        XCTAssertEqual(String(localized: reopened), "Restart this game to apply: Smooth scaling.")
    }

    func testClosingTheSettingsAfterARestoreKeepsTheRestoredSettings() {
        let game = GameEntry(id: "game", container: container, title: "Game", artworkPath: nil)
        let model = GameSettingsModel(game: game)
        model.settings.smoothScaling = true
        model.save()

        var restored = GameSettings()
        restored.smoothScaling = false
        restored.save(to: container.empoStateURL)
        model.reload()
        model.save()

        XCTAssertEqual(GameSettings.load(from: container.empoStateURL).smoothScaling, false)
    }

    func testCoreSettingsCompareWithTheSettingsAtLaunch() {
        let launched = MkxpLaunchedSettings(container: container)
        let edited = MkxpSettingsState(container: container)
        XCTAssertEqual(launched.restartRequiredChanges(to: edited), [])

        edited.settings.postloadScripts = true
        edited.save()

        XCTAssertEqual(
            launched.restartRequiredChanges(to: MkxpSettingsState(container: container)), ["Fix-up scripts"])
    }
}

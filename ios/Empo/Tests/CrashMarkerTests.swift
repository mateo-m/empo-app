// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

/// The user can close Empo from the app switcher after it goes to the
/// background. A mark that stays then makes the next launch report a
/// crash.
@MainActor
final class CrashMarkerTests: XCTestCase {
    private var container: GameContainer!
    private var game: GameEntry!

    override func setUp() async throws {
        container = GameContainer(folderName: "crash-marker-\(UUID().uuidString)")
        try container.ensureSubdirs()
        game = GameEntry(id: "crash-marker", container: container, title: "Game", artworkPath: nil)
    }

    override func tearDown() async throws {
        let appState = AppState.shared
        appState.phase = nil
        appState.selectedGame = nil
        appState.engineReady = false
        PauseManager.shared.reset()
        try? FileManager.default.removeItem(at: container.url)
    }

    private var markExists: Bool {
        FileManager.default.fileExists(atPath: container.sessionActiveMarkerURL.path)
    }

    private func pauseToTheLibrary() {
        let appState = AppState.shared
        appState.selectedGame = game
        appState.engineReady = true
        appState.phase = nil
        PauseManager.shared.pausedGame = game
    }

    func testAPausedGameLeavesNoMarkInTheBackground() {
        pauseToTheLibrary()
        EngineSessionCoordinator.shared.restoreCrashMarker(for: container)

        AppState.shared.sessionDidEnterBackground()

        XCTAssertFalse(markExists)
    }

    func testAPausedGameGetsItsMarkBackInTheForeground() {
        pauseToTheLibrary()

        AppState.shared.sessionWillEnterForeground()

        XCTAssertTrue(markExists)
    }

    func testAGameThatDrewNoFrameKeepsItsMarkInTheBackground() {
        let appState = AppState.shared
        appState.selectedGame = game
        appState.phase = .loading
        EngineSessionCoordinator.shared.restoreCrashMarker(for: container)

        appState.sessionDidEnterBackground()

        XCTAssertTrue(markExists)
    }
}

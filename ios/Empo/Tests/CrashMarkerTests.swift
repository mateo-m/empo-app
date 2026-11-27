// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

/// The next launch reports "The game crashed." when the session's crash
/// marker is still on disk after a close from the app switcher.
@MainActor
final class CrashMarkerTests: XCTestCase {
    private var container: GameContainer!
    private let appState = AppState.shared

    override func setUp() async throws {
        container = GameContainer(folderName: "crash-marker-\(UUID().uuidString)")
        try container.ensureSubdirs()
        appState.selectedGame = GameEntry(id: "game", container: container, title: "Game", artworkPath: nil)
        // `GameSession.configureEngine` writes the marker at the start.
        CrashTracker().writeMarker(for: container)
        appState.phase = .loading
    }

    override func tearDown() async throws {
        appState.shownError = nil
        appState.engineReady = false
        appState.phase = nil
        appState.selectedGame = nil
        try? FileManager.default.removeItem(at: container.url)
    }

    private var nextLaunchReportsACrash: Bool {
        FileManager.default.fileExists(atPath: container.sessionActiveMarkerURL.path)
    }

    /// The test host opens no core. mkxp waits for its alerts, and
    /// `coordinatorDidReportEngineError` then removes the marker.
    private func showErrorOfACoreThatWaits(_ message: String) {
        appState.coordinatorDidReportEngineError(message)
        appState.clearCrashMarker()
    }

    /// `RootView.dismissErrorAlert`, less the signal to the core.
    private func closeErrorAlert() {
        appState.shownError = nil
        appState.restoreCrashMarker()
    }

    func testStartErrorShownBeforeTheFirstFrameReportsNoCrash() {
        showErrorOfACoreThatWaits("ANGLE: eglInitialize failed")
        closeErrorAlert()

        XCTAssertFalse(nextLaunchReportsACrash)
    }

    func testGameThatRunsOnAfterAStartErrorReportsALaterCrash() {
        showErrorOfACoreThatWaits("Exception: RuntimeError")
        closeErrorAlert()
        appState.coordinatorFrameRendered()

        XCTAssertTrue(nextLaunchReportsACrash)
    }

    func testErrorAfterTheFirstFrameReportsALaterCrash() {
        appState.coordinatorFrameRendered()
        showErrorOfACoreThatWaits("Exception: RuntimeError")
        closeErrorAlert()

        XCTAssertTrue(nextLaunchReportsACrash)
    }
}

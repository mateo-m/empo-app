// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

/// Each test follows a session from its start to a close from the app
/// switcher. The next launch reports "The game crashed." when the
/// session's crash marker is still on disk.
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

    /// `RootView.dismissErrorAlert`, less the signal to the core.
    private func closeErrorAlert() {
        appState.shownError = nil
        appState.restoreCrashMarker()
    }

    /// What `RootView` does on the background and foreground events of a
    /// game that did not draw its first frame.
    private func goToTheBackgroundAndBack() {
        appState.writeBackgroundMarker()
        appState.removeBackgroundMarker()
    }

    func testStartErrorShownBeforeTheFirstFrameReportsNoCrash() {
        appState.coordinatorDidReportEngineError("ANGLE: eglInitialize failed")
        closeErrorAlert()
        goToTheBackgroundAndBack()

        XCTAssertFalse(nextLaunchReportsACrash)
    }

    func testStartErrorShownBeforeTheFirstFrameReportsNoCrashWhileTheAlertShows() {
        appState.coordinatorDidReportEngineError("ANGLE: eglInitialize failed")
        goToTheBackgroundAndBack()

        XCTAssertFalse(nextLaunchReportsACrash)
    }

    func testGameStuckWithNoErrorAndNoFirstFrameReportsACrash() {
        goToTheBackgroundAndBack()

        XCTAssertTrue(nextLaunchReportsACrash)
    }

    func testGameThatRunsOnAfterAStartErrorReportsALaterCrash() {
        appState.coordinatorDidReportEngineError("Exception: RuntimeError")
        closeErrorAlert()
        appState.coordinatorFrameRendered()

        XCTAssertTrue(nextLaunchReportsACrash)
    }

    func testErrorAfterTheFirstFrameReportsALaterCrash() {
        appState.coordinatorFrameRendered()
        appState.coordinatorDidReportEngineError("Exception: RuntimeError")
        closeErrorAlert()

        XCTAssertTrue(nextLaunchReportsACrash)
    }
}

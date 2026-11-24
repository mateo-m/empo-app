// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

@MainActor
final class BackgroundEndTests: XCTestCase {
    private var container: GameContainer!
    private let session = BackgroundSession(core: "MkxpCore", runner: .app, state: .paused)

    override func setUp() async throws {
        container = GameContainer(folderName: "background-end-\(UUID().uuidString)")
        try container.ensureSubdirs()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: container.url)
    }

    func testNextLaunchReportsTheSessionOnce() {
        CrashTracker().writeBackgroundMarker(session, for: container)

        let nextLaunch = CrashTracker()

        XCTAssertEqual(nextLaunch.consumeBackgroundEnd(), session)
        XCTAssertNil(nextLaunch.consumeBackgroundEnd())
        XCTAssertNil(CrashTracker().consumeBackgroundEnd())
    }

    func testNextLaunchReportsNothingWhenEmpoCameBack() {
        let tracker = CrashTracker()
        tracker.writeBackgroundMarker(session, for: container)
        tracker.removeBackgroundMarker(for: container)

        XCTAssertNil(CrashTracker().consumeBackgroundEnd())
    }

    func testMarkerOfAnEarlierInstallReportsNothing() throws {
        CrashTracker().writeBackgroundMarker(session, for: container)
        let marker = container.backgroundSessionMarkerURL.path
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: marker)

        XCTAssertNil(CrashTracker().consumeBackgroundEnd())
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testGameEndInTheBackgroundReportsTheSessionOnce() {
        let tracker = CrashTracker()
        tracker.writeBackgroundMarker(session, for: container)

        XCTAssertEqual(tracker.takeBackgroundMarker(for: container), session)
        XCTAssertNil(tracker.takeBackgroundMarker(for: container))
        XCTAssertNil(CrashTracker().consumeBackgroundEnd())
    }

    func testMarkerStateFollowsTheGame() {
        XCTAssertEqual(
            AppState.backgroundSessionState(phase: .loading, resuming: false, paused: false), .loading)
        XCTAssertEqual(
            AppState.backgroundSessionState(phase: .playing, resuming: false, paused: false), .playing)
        XCTAssertEqual(AppState.backgroundSessionState(phase: nil, resuming: true, paused: false), .playing)
        XCTAssertEqual(AppState.backgroundSessionState(phase: nil, resuming: false, paused: true), .paused)
        XCTAssertNil(AppState.backgroundSessionState(phase: nil, resuming: false, paused: false))
        XCTAssertNil(
            AppState.backgroundSessionState(
                phase: .ended(clean: false, started: true), resuming: false, paused: false))
    }

    func testDayWithNoMemoryEndSendsNothing() {
        XCTAssertNil(ErrorReports.backgroundExitTags(memoryLimit: 0, memoryPressure: 0, normal: 4))
    }

    func testDayWithAMemoryEndSendsTheCounts() {
        XCTAssertEqual(
            ErrorReports.backgroundExitTags(memoryLimit: 1, memoryPressure: 2, normal: 4),
            ["memory_limit_exits": "1", "memory_pressure_exits": "2", "normal_exits": "4"])
    }
}

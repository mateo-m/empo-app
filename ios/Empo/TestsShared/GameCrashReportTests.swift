// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Sentry
import XCTest

@testable import Empo

@MainActor
final class GameCrashReportTests: XCTestCase {
    private let detail = GameCrashDetail(
        runner: .gameProcess,
        ruby: GameCrashDetail.RubyVersion(setting: "auto", used: "19"),
        resources: DeviceResources(appMemoryMB: 900, freeMemoryMB: 120, thermalState: .serious),
        memoryWarning: true)

    func testCrashReportSaysHowTheGameEnded() {
        let event = ErrorReports.gameCrashEvent(game: nil, saveLoad: nil, end: .game, detail: detail)

        let tags = event.tags ?? [:]
        XCTAssertEqual(tags["ended_process"], "game")
        XCTAssertEqual(tags["runner"], "gameProcess")
        XCTAssertEqual(tags["thermal_state"], "serious")
        XCTAssertEqual(tags["memory_warning"], "yes")
        XCTAssertEqual(tags["ruby_setting"], "auto")
        XCTAssertEqual(tags["ruby_used"], "19")
        let memory = event.context?["memory"]
        XCTAssertEqual(memory?["app_memory_mb"] as? Int, 900)
        XCTAssertEqual(memory?["free_memory_mb"] as? Int, 120)
        XCTAssertEqual(event.fingerprint, ["crash", ""])
    }

    func testPlayerCrashSaysTheSignal() {
        let event = ErrorReports.gameCrashEvent(
            game: nil, saveLoad: nil, end: .player(.signal(11)), detail: detail)

        XCTAssertEqual(event.tags?["ended_process"], "player")
        XCTAssertEqual(event.tags?["exit"], "signal 11")
    }
}

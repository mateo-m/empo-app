// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import GameProbe

final class ControlsManifestLoaderLogTests: XCTestCase {
    private typealias Outcome = ControlsManifestLoader.LoadOutcome
    private let warning = ControlsManifestLoader.Finding(
        severity: .warning, code: "W001", path: "/touch", message: "a warning")

    func testLogsNoteThenFindingsWithTheFileOfTheLocation() {
        let outcome = Outcome(
            result: .init(
                manifest: ControlsManifest(version: 1, touch: nil), findings: [warning], location: .kirin),
            notes: [.rootSkippedBecauseEmpoExists])

        XCTAssertEqual(
            outcome.logLines,
            [
                "controls.json: Skipped controls.json at game root, using empo/controls.json",
                "kirin-touch-controls.json: [W001] (warning) /touch: a warning",
            ])
    }

    func testLogsRootFileThatIsNotEmpos() {
        let outcome = Outcome(result: .init(manifest: nil, findings: []), notes: [.rootUnclaimedNoVersion])

        XCTAssertEqual(
            outcome.logLines,
            ["controls.json: Ignored controls.json at game root (no version key, so not an Empo manifest)"])
    }

    func testLogsNewerVersion() {
        let outcome = Outcome(
            result: .init(manifest: nil, findings: [], ignoredNewerVersion: true, location: .empo))

        XCTAssertEqual(outcome.logLines, ["controls.json: Ignored manifest with version > 1"])
    }

    func testLoaderGivesNoManifestForRootFileThatIsNotEmpos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"buttons": []}"#.utf8).write(to: root.appendingPathComponent("controls.json"))

        let outcome = try XCTUnwrap(ControlsManifestLoader.load(gameRoot: root))

        XCTAssertEqual(outcome.notes, [.rootUnclaimedNoVersion])
        XCTAssertNil(outcome.result.manifest)
    }

    func testLoaderGivesNoManifestForNewerVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empo"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"version": 2}"#.utf8).write(to: root.appendingPathComponent("empo/controls.json"))

        let outcome = try XCTUnwrap(ControlsManifestLoader.load(gameRoot: root))

        XCTAssertTrue(outcome.result.ignoredNewerVersion)
        XCTAssertNil(outcome.result.manifest)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import XCTest

@testable import GameProbe

final class ControlsRejectionTests: XCTestCase {

    private var root: URL!
    private var store: LayoutProfileStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ControlsRejectionTests-\(UUID().uuidString)")
        let profilesRoot = root.appendingPathComponent("Profiles")
        let gamesRoot = root.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gamesRoot, withIntermediateDirectories: true)
        store = LayoutProfileStore(profilesRoot: profilesRoot, gamesRoot: gamesRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func parse(_ json: String) -> ControlsManifestLoader.Result {
        ControlsManifestLoader.parse(data: Data(json.utf8))
    }

    private func writeProfile(_ name: String, json: String) throws {
        try FileManager.default.createDirectory(
            at: store.profileURL(name), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.controlsURL(name))
    }

    func testGameControlsFromANewerEmpoGiveNoErrorCount() {
        XCTAssertEqual(parse(#"{ "version": 2 }"#).rejection, .newerVersion)
    }

    func testGameControlsWithErrorsGiveTheErrorCount() {
        let result = parse(
            #"""
            { "version": 1, "touch": { "portrait": {
              "buttons": [ { "key": "Enter", "x": true, "y": true } ] } } }
            """#)
        let errorCount = result.findings.filter { $0.severity == .error }.count
        XCTAssertNil(result.manifest)
        XCTAssertGreaterThanOrEqual(errorCount, 2)
        XCTAssertEqual(result.rejection, .errors(count: errorCount))
    }

    func testUsableGameControlsGiveNoRejection() {
        XCTAssertNil(parse(#"{ "version": 1 }"#).rejection)
    }

    func testLayoutProfileFromANewerEmpoGivesNoErrorCount() throws {
        try writeProfile("Future", json: #"{ "version": 2, "touch": {} }"#)
        XCTAssertEqual(store.readProfile("Future")?.rejection, .newerVersion)
    }

    func testLayoutProfileWithErrorsGivesTheErrorCount() throws {
        try writeProfile("Broken", json: #"{ "version": "one" }"#)
        XCTAssertEqual(store.readProfile("Broken")?.rejection, .errors(count: 1))
    }
}

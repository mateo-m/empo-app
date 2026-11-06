// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

final class JgpTests: XCTestCase {
    private var scratch: URL!
    private var game: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("JgpTests-\(UUID().uuidString)", isDirectory: true)
        game = scratch.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func writeManifest(icon: String) throws {
        let manifest = #"{"id": "t", "name": "T", "type": "mkxp-z", "icon": "\#(icon)"}"#
        try manifest.write(
            to: game.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    }

    func testIconInsideTheGameIsReadAndRemoved() throws {
        let icon = game.appendingPathComponent("icon.png")
        try Data([1, 2, 3]).write(to: icon)
        try writeManifest(icon: "icon.png")

        let bundle = try GameImporter.preprocessJgp(at: game)

        XCTAssertEqual(bundle.iconData, Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: icon.path))
    }

    func testIconOutsideTheGameIsNotReadOrRemoved() throws {
        let outside = scratch.appendingPathComponent("other-game", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try writeManifest(icon: "../other-game")

        let bundle = try GameImporter.preprocessJgp(at: game)

        XCTAssertNil(bundle.iconData)
        XCTAssertNil(bundle.iconURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testIconThroughALinkOutOfTheGameIsNotRead() throws {
        let outside = scratch.appendingPathComponent("other-game", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([4, 5, 6]).write(to: outside.appendingPathComponent("icon.png"))
        try FileManager.default.createSymbolicLink(
            at: game.appendingPathComponent("assets"), withDestinationURL: outside)
        try writeManifest(icon: "assets/icon.png")

        let bundle = try GameImporter.preprocessJgp(at: game)

        XCTAssertNil(bundle.iconData)
        XCTAssertNil(bundle.iconURL)
    }

}

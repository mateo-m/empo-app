// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import XCTest

@testable import GameProbe

final class MemberSourceTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(
            "MemberSourceTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("game/Saves"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func testAPathInsideTheRootResolvesAlsoWhenItDoesNotExistYet() {
        let game = root.appendingPathComponent("game")
        let source = MemberSource(container: game)

        XCTAssertEqual(
            source.url(root: .container, path: "Saves/new/Save1.rxdata")?.path,
            game.appendingPathComponent("Saves/new/Save1.rxdata").path)
    }

    func testAPathThroughALinkOrUpOutOfTheRootHasNoFile() throws {
        let game = root.appendingPathComponent("game")
        try fm.createSymbolicLink(
            at: game.appendingPathComponent("Linked"),
            withDestinationURL: root.appendingPathComponent("other"))
        let source = MemberSource(container: game, rescuedBuckets: ["Bucket": game])

        XCTAssertNil(source.url(root: .container, path: "Linked/Save1.rxdata"))
        XCTAssertNil(source.url(root: .container, path: "Linked"))
        XCTAssertNil(source.url(root: .container, path: "../other/Save1.rxdata"))
        XCTAssertNil(source.url(root: .rescuedSaves, path: "Bucket/Linked/Save1.rxdata"))
    }
}

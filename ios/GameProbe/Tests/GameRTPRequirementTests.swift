// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import GameProbe

final class GameRTPRequirementTests: XCTestCase {

    private func writeINI(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let iniURL = dir.appendingPathComponent("Game.ini")
        try contents.write(to: iniURL, atomically: true, encoding: .utf8)
        return dir
    }

    func testDetectsVXAceRTPWithSpacedEquals() throws {
        let gameDir = try writeINI(
            """
            [Game]
            rtp =RPGVXAce
            title =BLACK SOULS
            """)
        let requirement = GameRTPRequirement.detect(at: gameDir)
        XCTAssertEqual(requirement?.packages, ["RPGVXAce"])
        XCTAssertEqual(requirement?.friendlyNames, ["RPG Maker VX Ace"])
    }

    func testDetectsRTP1Key() throws {
        let gameDir = try writeINI(
            """
            [Game]
            RTP1=Standard
            """)
        XCTAssertEqual(GameRTPRequirement.detect(at: gameDir)?.packages, ["Standard"])
    }

    func testIgnoresEmptyRTPValue() throws {
        let gameDir = try writeINI(
            """
            [Game]
            RTP=
            """)
        XCTAssertNil(GameRTPRequirement.detect(at: gameDir))
    }

    func testReturnsNilWhenNoRTPKeys() throws {
        let gameDir = try writeINI(
            """
            [Game]
            Title=Pokemon Reborn
            """)
        XCTAssertNil(GameRTPRequirement.detect(at: gameDir))
    }
}

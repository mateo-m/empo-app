// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

@MainActor
final class BackupGameArtworkTests: XCTestCase {

    func testABackedUpGameShowsItsLibraryArtwork() {
        let games = [
            GameEntry(
                id: "Rejuvenation", container: GameContainer(folderName: "Rejuvenation"),
                title: "Rejuvenation", artworkPath: "/art/rejuvenation.png"),
            GameEntry(
                id: "Insurgence", container: GameContainer(folderName: "Insurgence"),
                title: "Insurgence", artworkPath: nil),
        ]
        XCTAssertEqual(
            BackupGameArtwork.artworkPath(
                ofGameKey: BackupKeys.gameKey(containerFolderName: "Rejuvenation"), in: games),
            "/art/rejuvenation.png")
        XCTAssertNil(
            BackupGameArtwork.artworkPath(
                ofGameKey: BackupKeys.gameKey(containerFolderName: "A removed game"), in: games))
        XCTAssertNil(BackupGameArtwork.artworkPath(ofGameKey: nil, in: games))
    }
}

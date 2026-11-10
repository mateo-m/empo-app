// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

@MainActor
final class EditZoneCaptionTests: XCTestCase {

    private func caption(
        manifest: ControlsRejection? = nil, profile: ControlsRejection? = nil
    ) -> String? {
        PlayerView.editZoneCaption(manifest: manifest, profile: profile, pinFellThrough: false)?.key
    }

    func testGameControlsFromANewerEmpoAskForAnUpdate() {
        XCTAssertEqual(
            caption(manifest: .newerVersion),
            "This game's controls need a newer version of Empo. Update Empo to use them.")
    }

    func testLayoutProfileFromANewerEmpoAsksForAnUpdate() {
        XCTAssertEqual(
            caption(profile: .newerVersion),
            "This layout profile needs a newer version of Empo. Update Empo to use it.")
    }

    func testErrorsStillShowTheirCount() {
        XCTAssertEqual(
            caption(manifest: .errors(count: 3)),
            "This game's controls file has %lld errors, so Empo used its own layout.")
        XCTAssertEqual(
            caption(profile: .errors(count: 2)),
            "Your layout profile has %lld errors, so Empo used its own layout.")
    }

    func testEveryCaptionHasATranslation() throws {
        let url = try XCTUnwrap(
            Bundle(for: ControlsLayout.self).url(forResource: "de", withExtension: "lproj"))
        let german = try XCTUnwrap(Bundle(url: url))
        for key in [
            "This game's controls need a newer version of Empo. Update Empo to use them.",
            "This layout profile needs a newer version of Empo. Update Empo to use it.",
            "Couldn't save your layout. Free up some space and try again.",
        ] {
            XCTAssertNotEqual(german.localizedString(forKey: key, value: nil, table: nil), key)
        }
    }
}

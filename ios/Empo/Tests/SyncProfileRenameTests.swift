// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

@MainActor
final class SyncProfileRenameTests: XCTestCase {

    func testARenameOfOnlyTheCaseStillAppliesTheControls() throws {
        let store = LayoutProfilesManager.store
        let name = "Case Sync \(UUID().uuidString.prefix(8))"
        try LayoutProfilesManager.createProfileFromBuiltins(rawName: name)
        defer { try? store.deleteProfile(name) }

        var touch = try XCTUnwrap(store.readProfile(name)?.touch)
        var portrait = try XCTUnwrap(touch.portrait)
        var buttons = try XCTUnwrap(portrait.buttons)
        buttons[0].x = 0.42
        portrait.buttons = buttons
        touch.portrait = portrait

        let renamed = name.lowercased()
        var identities = SyncProfileIdentities()
        identities.ids[name] = "profile-1"
        let model = SyncDocumentModel(layoutProfiles: [
            "profile-1": SyncProfile(
                name: renamed, controls: TouchSectionSyncCoder.controls(of: touch))
        ])
        SyncLocalValues.applyProfiles(model, identities: &identities)

        XCTAssertEqual(store.readProfile(renamed)?.touch?.portrait?.buttons?.first?.x, 0.42)
        XCTAssertEqual(identities.name(ofId: "profile-1"), renamed)
    }
}

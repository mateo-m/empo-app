// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

@MainActor
final class SyncProfileRenameTests: XCTestCase {

    private let store = LayoutProfilesManager.store
    private let tag = String(UUID().uuidString.prefix(8))

    override func tearDown() async throws {
        for name in store.listProfiles() where name.lowercased().contains(tag.lowercased()) {
            try? store.deleteProfile(name)
        }
    }

    private func makeProfile(_ name: String, buttonX: Double) throws -> TouchSection {
        try LayoutProfilesManager.createProfileFromBuiltins(rawName: name)
        let touch = try touch(of: name, buttonX: buttonX)
        try store.writeProfile(name, touch: touch)
        return touch
    }

    private func touch(of name: String, buttonX: Double) throws -> TouchSection {
        var touch = try XCTUnwrap(store.readProfile(name)?.touch)
        var portrait = try XCTUnwrap(touch.portrait)
        var buttons = try XCTUnwrap(portrait.buttons)
        buttons[0].x = buttonX
        portrait.buttons = buttons
        touch.portrait = portrait
        return touch
    }

    private func buttonX(_ name: String) -> Double? {
        store.readProfile(name)?.touch?.portrait?.buttons?.first?.x
    }

    private func apply(
        id: String, name: String, touch: TouchSection, _ identities: inout SyncProfileIdentities
    ) {
        let model = SyncDocumentModel(layoutProfiles: [
            id: SyncProfile(name: name, controls: TouchSectionSyncCoder.controls(of: touch))
        ])
        SyncLocalValues.applyProfiles(model, identities: &identities)
    }

    func testARenameOfOnlyTheCaseStillAppliesTheControls() throws {
        let name = "Case Sync \(tag)"
        try LayoutProfilesManager.createProfileFromBuiltins(rawName: name)
        let incoming = try touch(of: name, buttonX: 0.42)

        let renamed = name.lowercased()
        var identities = SyncProfileIdentities()
        identities.ids[name] = "profile-1"
        apply(id: "profile-1", name: renamed, touch: incoming, &identities)

        XCTAssertEqual(buttonX(renamed), 0.42)
        XCTAssertEqual(identities.name(ofId: "profile-1"), renamed)
        XCTAssertTrue(store.listProfiles().contains(renamed), "the folder takes the new case")
        let next = SyncLocalValues.current(identities: &identities)
        XCTAssertEqual(next.layoutProfiles["profile-1"]?.name, renamed, "no second record")
    }

    func testARenameAfterTheFolderWentAwayCreatesTheProfile() throws {
        let gone = "Gone \(tag)"
        let back = "Back \(tag)"
        let incoming = try makeProfile(gone, buttonX: 0.42)
        try store.deleteProfile(gone)

        var identities = SyncProfileIdentities()
        identities.ids[gone] = "profile-2"
        apply(id: "profile-2", name: back, touch: incoming, &identities)

        XCTAssertEqual(buttonX(back), 0.42)
        XCTAssertEqual(identities.name(ofId: "profile-2"), back)
    }

    func testARenameOntoATakenNameMovesTheOtherProfileAside() throws {
        let mine = "Mine \(tag)"
        let theirs = "Theirs \(tag)"
        let incoming = try makeProfile(mine, buttonX: 0.42)
        _ = try makeProfile(theirs, buttonX: 0.33)

        var identities = SyncProfileIdentities()
        identities.ids[mine] = "profile-3"
        apply(id: "profile-3", name: theirs, touch: incoming, &identities)

        XCTAssertEqual(buttonX(theirs), 0.42)
        XCTAssertFalse(store.profileExists(mine))
        let aside = store.listProfiles().filter { $0 != theirs && $0.hasPrefix(theirs) }
        XCTAssertEqual(aside.map(buttonX), [0.33], "the other profile keeps its controls")
    }

    func testAProfileWithALongNameFromAnotherDeviceMovesTheLocalOneAside() throws {
        let start = "\(tag) "
        let name = start + String(repeating: "L", count: LayoutProfileStore.maxNameLength - start.count)
        _ = try makeProfile(name, buttonX: 0.33)
        let incoming = try touch(of: name, buttonX: 0.42)

        var identities = SyncProfileIdentities()
        identities.ids[name] = "local-profile"
        apply(id: "remote-profile", name: name, touch: incoming, &identities)

        XCTAssertEqual(buttonX(name), 0.42)
        XCTAssertEqual(identities.ids[name], "remote-profile")
        let aside = store.listProfiles().filter { $0 != name && $0.hasPrefix(tag) }
        XCTAssertEqual(aside.map(buttonX), [0.33], "the local profile keeps its controls")
        XCTAssertEqual(aside.compactMap { identities.ids[$0] }, ["local-profile"])
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

@MainActor
final class PlayerActionRegistryTests: XCTestCase {
    func testShowCheatsRunsOnlyInGamesWithCheats() {
        var cheatsEnabled = false
        let registry = PlayerActionRegistry(
            engine: PlayerEngine(
                fastForwardMultiplier: { 1 }, setFastForwardMultiplier: { _ in },
                setCheatsEnabled: { cheatsEnabled = $0 }, tapKey: { _, _ in }))

        registry.runtime.bind(fastForwardMultiplier: nil, cheatsAvailable: false)
        XCTAssertFalse(registry.isAvailable(EmpoActionCatalog.toggleCheats))
        registry.handle(EmpoActionCatalog.toggleCheats, pressed: true)
        XCTAssertFalse(cheatsEnabled)

        registry.runtime.bind(fastForwardMultiplier: nil, cheatsAvailable: true)
        registry.handle(EmpoActionCatalog.toggleCheats, pressed: true)
        XCTAssertTrue(cheatsEnabled)
    }

    func testPressOfAnUnavailableActionIsRefused() {
        let registry = PlayerActionRegistry(engine: .none)

        registry.runtime.bind(fastForwardMultiplier: nil, cheatsAvailable: false)
        XCTAssertFalse(registry.handle(EmpoActionCatalog.fastForwardHold, pressed: true))
        XCTAssertFalse(registry.handle("$fromANewerEmpo", pressed: true))

        registry.runtime.bind(fastForwardMultiplier: 4, cheatsAvailable: false)
        XCTAssertTrue(registry.handle(EmpoActionCatalog.fastForwardHold, pressed: true))
    }

    func testUnavailableNoteNamesTheReason() {
        XCTAssertEqual(
            BindingsCatalog.unavailableActionNote(EmpoActionCatalog.toggleCheats, in: .editModeBadge),
            "This game has no cheats.")
        XCTAssertEqual(
            BindingsCatalog.unavailableActionNote(EmpoActionCatalog.fastForwardHold, in: .editModeBadge),
            "Turn this on in this game's settings")
        XCTAssertEqual(
            BindingsCatalog.unavailableActionNote(
                EmpoActionCatalog.fastForwardHold, in: .bindingList(.thisGame)),
            "Fast forward is off for this game. Turn it on in this game's settings.")
    }

    func testKeyCanStandInForAButtonButAButtonCannot() {
        let forKey = BindingsCatalog.targetChoices(
            for: .key("Enter"), scope: .thisGame, isAvailable: { _ in true })
        let forButton = BindingsCatalog.targetChoices(
            for: .element("a"), scope: .thisGame, isAvailable: { _ in true })

        XCTAssertFalse(forKey.elements.isEmpty)
        XCTAssertTrue(forButton.elements.isEmpty)
        XCTAssertEqual(forButton.actions.last?.target, BindingMap.Target.unbound)
    }
}

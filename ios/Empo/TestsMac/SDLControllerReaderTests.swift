// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import GameProbe
import XCTest

@testable import Empo

/// Drives `ControllerInputManager` on the Mac with SDL virtual pads.
/// SDL makes the GUID of a virtual pad from its name, so each test
/// gives its pad a name of its own. A mapping that one test adds then
/// does not apply to the pad of another test.
@MainActor
final class SDLControllerReaderTests: XCTestCase {
    private var manager: ControllerInputManager!
    private var actions: [String] = []
    private var connections = 0
    private var pad: SDLVirtualPad?
    private var isAppActive = true

    override func setUp() async throws {
        isAppActive = true
        SDLControllers.shared.isAppActive = { [unowned self] in isAppActive }
        actions = []
        connections = 0
        manager = ControllerInputManager(keys: HeldKeys(send: { _, _ in }))
        manager.actionHandler = { [unowned self] name, pressed in
            actions.append("\(name) \(pressed ? "down" : "up")")
            return true
        }
        manager.connectionHandler = { [unowned self] in connections += 1 }
        manager.updateResolvedMap([
            "a": .action("confirm"), "+leftx": .action("right"), "-lefty": .action("up"),
        ])
        manager.start()
        pad = SDLVirtualPad(name: "Empo Reader Test \(name)", isRecognized: true)
        try await waitUntil { self.connections == 1 }
    }

    override func tearDown() async throws {
        pad?.detach()
        manager.stop()
        manager = nil
        SDLControllers.shared.isAppActive = { NSApp.isActive }
    }

    private func becomeActive() {
        isAppActive = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }

    func testPressAndReleaseInOnePumpGiveBothEdges() async throws {
        pad?.apply(.buttonA(pressed: true))
        pad?.apply(.buttonA(pressed: false))
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions, ["confirm down", "confirm up"])
    }

    func testQuickStickTapGivesBothEdges() async throws {
        pad?.apply(.leftStick(x: 1, y: 0))
        pad?.apply(.leftStick(x: 0, y: 0))
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions, ["right down", "right up"])
    }

    func testStickUpIsUp() async throws {
        pad?.apply(.leftStick(x: 0, y: 1))
        try await waitUntil { self.actions.count == 1 }
        pad?.apply(.leftStick(x: 0, y: 0))
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions, ["up down", "up up"])
    }

    func testDiagonalReadsBothAxesOfOneReport() async throws {
        pad?.apply(.leftStick(x: 1, y: 0))
        pad?.apply(.leftStick(x: 0.7, y: 0.7))
        pad?.apply(.leftStick(x: 0, y: 0))
        try await waitUntil { self.actions.count == 4 }
        XCTAssertEqual(actions, ["right down", "up down", "right up", "up up"])
    }

    func testDisconnectReleasesTheHeldStick() async throws {
        pad?.apply(.leftStick(x: 1, y: 0))
        try await waitUntil { self.actions.count == 1 }
        pad?.detach()
        pad = nil
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions, ["right down", "right up"])
    }

    func testRemapThatDropsTheStickReleasesIt() async throws {
        let pad = try XCTUnwrap(pad)
        pad.apply(.leftStick(x: 1, y: 0))
        try await waitUntil { self.actions.count == 1 }
        SDLControllers.shared.add(mappings: [
            "\(SDLControllers.guid(of: pad.id)),Empo Reader Test,a:b0,platform:Mac OS X,"
        ])
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions, ["right down", "right up"])
    }

    func testPressInTheBackgroundWaitsForTheApp() async throws {
        isAppActive = false
        pad?.apply(.buttonA(pressed: true))
        try await settle()
        XCTAssertEqual(actions, [])
        becomeActive()
        try await waitUntil { self.actions.count == 1 }
        XCTAssertEqual(actions, ["confirm down"])
    }

    func testReleaseInTheBackgroundReachesTheAppLater() async throws {
        pad?.apply(.leftStick(x: 0, y: 1))
        try await waitUntil { self.actions.count == 1 }
        isAppActive = false
        pad?.apply(.leftStick(x: 0, y: 0))
        try await settle()
        XCTAssertEqual(actions, ["up down"])
        becomeActive()
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions, ["up down", "up up"])
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import GameProbe

@available(iOS 16, macOS 13, *)
@MainActor
final class HeldKeysTests: XCTestCase {
    private struct Event: Equatable {
        let scancode: Int32
        let pressed: Bool
    }

    private var events: [Event] = []

    private func makeKeys() -> HeldKeys<String> {
        HeldKeys { [unowned self] scancode, pressed in
            events.append(Event(scancode: scancode, pressed: pressed))
        }
    }

    func testOnlyTheLastHolderReleases() async throws {
        let keys = makeKeys()
        keys.hold(40, by: "touch")
        keys.hold(40, by: "controller")
        keys.hold(40, by: "controller")
        XCTAssertEqual(events, [Event(scancode: 40, pressed: true)])

        keys.release(40, by: "touch")
        XCTAssertEqual(events.count, 1)

        try await Task.sleep(for: HeldKeys<String>.minimumHold)
        keys.release(40, by: "controller")
        XCTAssertEqual(events, [Event(scancode: 40, pressed: true), Event(scancode: 40, pressed: false)])
    }

    func testAReleaseThatComesTooSoonWaitsForTheMinimumHold() async throws {
        let keys = makeKeys()
        keys.hold(40, by: "touch")
        keys.release(40, by: "touch")
        XCTAssertEqual(events, [Event(scancode: 40, pressed: true)])

        try await Task.sleep(for: HeldKeys<String>.minimumHold * 3)
        XCTAssertEqual(events, [Event(scancode: 40, pressed: true), Event(scancode: 40, pressed: false)])
    }

    func testAHolderThatHoldsAgainCancelsItsWaitingRelease() async throws {
        let keys = makeKeys()
        keys.hold(40, by: "touch")
        keys.release(40, by: "touch")
        keys.hold(40, by: "touch")

        try await Task.sleep(for: HeldKeys<String>.minimumHold * 3)
        XCTAssertEqual(events, [Event(scancode: 40, pressed: true)])

        keys.release(40, by: "touch")
        XCTAssertEqual(events, [Event(scancode: 40, pressed: true), Event(scancode: 40, pressed: false)])
    }

    func testATapOnAHeldKeySendsNoEvent() async throws {
        let keys = makeKeys()
        keys.hold(40, by: "touch")
        try await Task.sleep(for: HeldKeys<String>.minimumHold)

        keys.tap(40, holdMilliseconds: 10, by: "tap")
        try await Task.sleep(for: HeldKeys<String>.minimumHold * 2)
        XCTAssertEqual(events, [Event(scancode: 40, pressed: true)])

        keys.release(40, by: "touch")
        XCTAssertEqual(events, [Event(scancode: 40, pressed: true), Event(scancode: 40, pressed: false)])
    }

    func testATapReleasesAfterItsHoldTime() async throws {
        let keys = makeKeys()
        keys.tap(40, holdMilliseconds: 150, by: "tap")

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(events, [Event(scancode: 40, pressed: true)])

        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(events, [Event(scancode: 40, pressed: true), Event(scancode: 40, pressed: false)])
    }

    func testClearCancelsTheWaitingTapRelease() async throws {
        let keys = makeKeys()
        keys.tap(40, holdMilliseconds: 50, by: "tap")
        keys.clear()
        keys.hold(40, by: "touch")

        try await Task.sleep(for: HeldKeys<String>.minimumHold * 3)
        XCTAssertEqual(
            events,
            [
                Event(scancode: 40, pressed: true), Event(scancode: 40, pressed: false),
                Event(scancode: 40, pressed: true),
            ])
    }

    func testReleaseWhereDropsOnlyTheMatchingHolders() {
        let keys = makeKeys()
        keys.hold(40, by: "controller")
        keys.hold(41, by: "controller")
        keys.hold(41, by: "touch")
        events.removeAll()

        keys.release { $0 == "controller" }
        keys.release(41, by: "controller")
        XCTAssertEqual(events.filter { $0.scancode == 41 }, [])
    }

    func testClearReleasesEveryKeyAndForgetsTheHolders() {
        let keys = makeKeys()
        keys.hold(40, by: "touch")
        events.removeAll()

        keys.clear()
        XCTAssertEqual(events, [Event(scancode: 40, pressed: false)])

        keys.hold(40, by: "touch")
        XCTAssertEqual(events.last, Event(scancode: 40, pressed: true))
    }
}

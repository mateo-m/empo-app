import GameController
import GameProbe
import XCTest
import os

@testable import Empo

/// Drives `ControllerInputManager` with snapshot controllers. A
/// snapshot has the same element dictionaries as a paired pad, and
/// `setValue` fires its element handlers.
///
/// On iOS a snapshot stays in `GCController.controllers()` for the
/// rest of the process, so every later `start()` attaches the pads of
/// earlier tests too. The tests match log lines and edges to their
/// own pad, and `tearDown` returns every element to rest so a
/// leftover pad never carries a press into the next test.
@MainActor
final class ControllerInputManagerTests: XCTestCase {
    private var manager: ControllerInputManager!
    private var actions: [(String, Bool)] = []
    private var pressedElements: [String] = []
    private var logLines: [String] = []
    private var pads: [GCController] = []

    override func setUp() async throws {
        actions = []
        pressedElements = []
        logLines = []
        pads = []
        manager = ControllerInputManager()
        manager.actionHandler = { [unowned self] name, pressed in actions.append((name, pressed)) }
        manager.elementActivityHandler = { [unowned self] element in pressedElements.append(element) }
        manager.deviceLogHandler = { [unowned self] line in logLines.append(line) }
        manager.start()
    }

    override func tearDown() async throws {
        for pad in pads {
            let profile = pad.physicalInputProfile
            for button in profile.buttons.values { button.setValue(0) }
            for dpad in profile.dpads.values { dpad.setValueForXAxis(0, yAxis: 0) }
        }
        manager.stop()
        manager = nil
    }

    // MARK: - Micro profile (the FlipPad shape, issue #140)

    func testMicroGamepadButtonsAndDpadReachTheResolvedMap() async throws {
        let pad = GCController.withMicroGamepad()
        let profile = try XCTUnwrap(pad.microGamepad)
        manager.updateResolvedMap(["a": .action("confirm"), "dpup": .action("up")])
        try await connect(pad)

        XCTAssertNil(pad.extendedGamepad)
        XCTAssertTrue(connectLine(for: pad)?.contains("profile=GCMicroGamepad") ?? false)

        profile.buttonA.setValue(1)
        try await waitUntil { self.actions.count == 1 }
        XCTAssertEqual(actions.last?.0, "confirm")
        XCTAssertEqual(actions.last?.1, true)
        XCTAssertTrue(logLines.contains("controller input: id=\(id(of: pad)) first element=a"))

        profile.buttonA.setValue(0)
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions.last?.1, false)

        profile.dpad.setValueForXAxis(0, yAxis: 1)
        try await waitUntil { self.actions.count == 3 }
        XCTAssertEqual(actions.last?.0, "up")
        XCTAssertEqual(pressedElements, ["a", "dpup"])
    }

    // MARK: - Extended profile

    func testExtendedGamepadShouldersTriggersAndOptionsReachTheMap() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap([
            "leftshoulder": .action("l"), "righttrigger": .action("rt"), "back": .action("back"),
        ])
        try await connect(pad)

        profile.leftShoulder.setValue(1)
        profile.rightTrigger.setValue(0.9)
        profile.buttonOptions?.setValue(1)
        try await waitUntil { self.actions.count == 3 }
        XCTAssertEqual(actions.map(\.0), ["l", "rt", "back"])

        profile.rightTrigger.setValue(0.45)
        try await settle()
        XCTAssertEqual(actions.count, 3, "a trigger releases below 0.4, not below 0.5")
        profile.rightTrigger.setValue(0.3)
        try await waitUntil { self.actions.count == 4 }
        XCTAssertEqual(actions.last?.0, "rt")
        XCTAssertEqual(actions.last?.1, false)
    }

    func testStickSendsDiagonalsAndHoldsItsSectorAtTheBoundary() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap(["+leftx": .action("right"), "-lefty": .action("up")])
        try await connect(pad)

        // 25 degrees above the x axis: one direction.
        profile.leftThumbstick.setValueForXAxis(0.8, yAxis: 0.37)
        try await waitUntil { self.actions.count == 1 }
        XCTAssertEqual(actions.map(\.0), ["right"])

        // 33 degrees: past the boundary, inside the margin.
        profile.leftThumbstick.setValueForXAxis(0.75, yAxis: 0.49)
        try await settle()
        XCTAssertEqual(actions.count, 1, "the held sector survives a wobble past its boundary")

        // 45 degrees: both directions, in one sample.
        profile.leftThumbstick.setValueForXAxis(0.6, yAxis: 0.6)
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions.map(\.0), ["right", "up"])
        XCTAssertEqual(actions.map(\.1), [true, true])

        // Straight up: right releases, up stays.
        profile.leftThumbstick.setValueForXAxis(0.1, yAxis: 0.9)
        try await waitUntil { self.actions.count == 3 }
        XCTAssertEqual(actions.last?.0, "right")
        XCTAssertEqual(actions.last?.1, false)

        profile.leftThumbstick.setValueForXAxis(0, yAxis: 0)
        try await waitUntil { self.actions.count == 4 }
        XCTAssertEqual(actions.last?.0, "up")
        XCTAssertEqual(actions.last?.1, false)
    }

    // MARK: - Paths the rewrite added

    /// `MainActor.assumeIsolated` would trap here. The manager sets
    /// the handler queue to main, and this test moves it away.
    func testHandlerOffTheMainQueueStillArrives() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap(["y": .action("menu")])
        try await connect(pad)

        pad.handlerQueue = DispatchQueue(label: "sh.mateo.empo.tests.controller")
        let offMain = OSAllocatedUnfairLock(initialState: false)
        profile.buttonX.pressedChangedHandler = { _, _, _ in
            offMain.withLock { $0 = !Thread.isMainThread }
        }
        profile.buttonX.setValue(1)
        profile.buttonY.setValue(1)
        try await waitUntil { self.actions.count == 1 }
        XCTAssertTrue(offMain.withLock { $0 }, "the pad did not move its handlers off the main queue")
        XCTAssertEqual(actions.last?.0, "menu")
        profile.buttonY.setValue(0)
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions.last?.1, false)
    }

    /// A release the framework never delivered, as when the app was
    /// inactive, must clear when the app becomes active.
    func testBecomingActiveReleasesAKeyWhoseCallbackWasLost() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap(["a": .action("$fastForward")])
        try await connect(pad)

        profile.buttonA.setValue(1)
        try await waitUntil { self.actions.count == 1 }

        profile.buttonA.pressedChangedHandler = nil
        profile.buttonA.setValue(0)
        try await settle()
        XCTAssertEqual(actions.count, 1, "the lost callback leaves the action held")

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions.last?.0, "$fastForward")
        XCTAssertEqual(actions.last?.1, false)
    }

    func testBecomingActiveWithNothingChangedSendsNoEdges() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap(["a": .action("confirm"), "+leftx": .action("right")])
        try await connect(pad)

        profile.buttonA.setValue(1)
        profile.leftThumbstick.setValueForXAxis(0.9, yAxis: 0)
        try await waitUntil { self.actions.count == 2 }

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await settle()
        XCTAssertEqual(actions.count, 2)
    }

    func testSecondConnectNotificationDoesNotDuplicateEdges() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap(["b": .action("cancel")])
        try await connect(pad)
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: pad)
        try await settle()

        profile.buttonB.setValue(1)
        try await settle()
        XCTAssertEqual(actions.map(\.1), [true])
        XCTAssertEqual(pressedElements, ["b"])
    }

    func testInputAfterStopDoesNothing() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap(["a": .action("confirm")])
        try await connect(pad)

        profile.buttonA.setValue(1)
        try await waitUntil { self.actions.count == 1 }
        manager.stop()
        XCTAssertEqual(actions.map(\.1), [true, false], "stop releases what it holds")

        profile.buttonA.setValue(0)
        profile.buttonA.setValue(1)
        try await settle()
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(pressedElements, ["a"])
    }

    func testTwoControllersMergeTheSameElement() async throws {
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        manager.updateResolvedMap(["a": .action("confirm")])
        try await connect(first)
        try await connect(second)

        first.extendedGamepad?.buttonA.setValue(1)
        second.extendedGamepad?.buttonA.setValue(1)
        try await settle()
        XCTAssertEqual(actions.map(\.1), [true], "one press for two pads")

        first.extendedGamepad?.buttonA.setValue(0)
        try await settle()
        XCTAssertEqual(actions.count, 1, "the second pad still holds it")

        second.extendedGamepad?.buttonA.setValue(0)
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions.last?.1, false)
    }

    func testDetachOfOnePadKeepsTheOtherPadsKey() async throws {
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        manager.updateResolvedMap(["a": .action("confirm")])
        try await connect(first)
        try await connect(second)

        first.extendedGamepad?.buttonA.setValue(1)
        second.extendedGamepad?.buttonA.setValue(1)
        try await settle()
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: first)
        try await settle()
        XCTAssertEqual(actions.map(\.1), [true])

        second.extendedGamepad?.buttonA.setValue(0)
        try await waitUntil { self.actions.count == 2 }
    }

    func testStickReleaseWhileSuppressedLeavesNothingHeld() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap(["+leftx": .action("right")])
        try await connect(pad)

        profile.leftThumbstick.setValueForXAxis(0.9, yAxis: 0)
        try await waitUntil { self.actions.count == 1 }
        manager.suppressInjection = true
        XCTAssertEqual(actions.map(\.1), [true, false])

        profile.leftThumbstick.setValueForXAxis(0, yAxis: 0)
        try await settle()
        manager.suppressInjection = false
        profile.leftThumbstick.setValueForXAxis(0.9, yAxis: 0)
        try await waitUntil { self.actions.count == 3 }
        XCTAssertEqual(actions.last?.1, true)
    }

    func testDisconnectReleasesHeldActionsAndStopsListening() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap(["a": .action("$fastForward")])
        try await connect(pad)

        profile.buttonA.setValue(1)
        try await waitUntil { self.actions.count == 1 }

        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: pad)
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions.last?.0, "$fastForward")
        XCTAssertEqual(actions.last?.1, false)

        profile.buttonA.setValue(0)
        profile.buttonA.setValue(1)
        try await settle()
        XCTAssertEqual(actions.count, 2, "a detached pad dispatches nothing")
    }

    /// A press and its release queued in the same main-queue turn
    /// must both reach the reducer.
    func testPressAndReleaseInOneTurnBothArrive() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap(["x": .action("tap")])
        try await connect(pad)

        profile.buttonX.setValue(1)
        profile.buttonX.setValue(0)
        try await waitUntil { self.actions.count == 2 }
        XCTAssertEqual(actions.map(\.1), [true, false])
    }

    func testSuppressionReleasesAndSwallowsInput() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try XCTUnwrap(pad.extendedGamepad)
        manager.updateResolvedMap(["b": .action("cancel")])
        try await connect(pad)

        profile.buttonB.setValue(1)
        try await waitUntil { self.actions.count == 1 }
        manager.suppressInjection = true
        XCTAssertEqual(actions.map(\.1), [true, false])

        profile.buttonB.setValue(0)
        profile.buttonB.setValue(1)
        try await waitUntil { self.pressedElements.count == 2 }
        XCTAssertEqual(pressedElements, ["b", "b"], "listen mode still reports the element")
        XCTAssertEqual(actions.count, 2, "listen mode dispatches nothing")
    }

    // MARK: - GCVirtualController

    func testVirtualControllerConnectsThroughTheSystemPath() async throws {
        let configuration = GCVirtualController.Configuration()
        configuration.elements = [GCInputButtonA]
        let virtual = GCVirtualController(configuration: configuration)
        manager.updateResolvedMap(["a": .action("confirm")])
        try await virtual.connect()
        defer { virtual.disconnect() }

        guard let pad = virtual.controller else {
            throw XCTSkip("this simulator did not surface the virtual controller")
        }
        pads.append(pad)
        try await waitUntil { self.connectLine(for: pad) != nil }
        virtual.setValue(1, forButtonElement: GCInputButtonA)
        try await waitUntil { self.actions.count == 1 }
        XCTAssertEqual(actions.last?.0, "confirm")
    }

    // MARK: - Helpers

    /// Same scheme as the manager's `controllerID`, so a log line
    /// matches its pad by identity.
    private func id(of pad: GCController) -> String {
        String(UInt(bitPattern: ObjectIdentifier(pad)))
    }

    private func connectLine(for pad: GCController) -> String? {
        logLines.first { $0.hasPrefix("controller connected:") && $0.contains(" id=\(id(of: pad)) ") }
    }

    private func connect(_ pad: GCController) async throws {
        pads.append(pad)
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: pad)
        try await waitUntil { self.connectLine(for: pad) != nil }
    }

    /// The framework queues element handlers on the handler queue and
    /// the connect observers hop through a Task. Neither offers a
    /// completion signal, so the tests poll the observable result.
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition did not hold within 2 s", file: file, line: line)
    }

    /// Enough main-queue turns for queued handlers to land.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }
}

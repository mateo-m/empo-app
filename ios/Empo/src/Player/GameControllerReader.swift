// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameController

/// Reads controllers through Apple's GameController for
/// `ControllerInputManager` on iOS.
@MainActor
final class GameControllerReader {
    private unowned let manager: ControllerInputManager
    private var running = false
    private var controllers: [String: GCController] = [:]
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    init(manager: ControllerInputManager) {
        self.manager = manager
    }

    func start() {
        running = true
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            Task { @MainActor in
                self?.attach(controller)
            }
        }

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            Task { @MainActor in
                self?.detach(controller)
            }
        }

        var controllers = GCController.controllers()
        #if DEBUG
        controllers += [UITestVirtualController.controller].compactMap { $0 }
        #endif
        for controller in controllers {
            attach(controller)
        }
    }

    func stop() {
        running = false
        if let connectObserver {
            NotificationCenter.default.removeObserver(connectObserver)
        }
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
        connectObserver = nil
        disconnectObserver = nil

        for controller in controllers.values {
            clearHandlers(on: controller)
        }
        controllers.removeAll()
    }

    func pollAll() {
        for (controllerID, controller) in controllers {
            poll(controllerID: controllerID, controller: controller)
        }
    }

    private func logDevice(_ controller: GCController) {
        guard let log = manager.deviceLogHandler else { return }
        let profile = controller.physicalInputProfile
        let elements = profile.elements.keys.sorted().joined(separator: ", ")
        log(
            """
            controller connected: \(controller.vendorName ?? "unnamed") \
            [\(controller.productCategory)] \
            id=\(Self.controllerID(controller)) \
            profile=\(type(of: profile)) \
            extended=\(controller.extendedGamepad != nil) \
            micro=\(controller.microGamepad != nil) \
            mappable=\(Self.isMappable(controller)) \
            elements=[\(elements)]
            """
        )
    }

    private static func controllerID(_ controller: GCController) -> String {
        String(UInt(bitPattern: ObjectIdentifier(controller)))
    }

    private func attach(_ controller: GCController) {
        guard running else { return }
        #if DEBUG
        guard UITestVirtualController.admits(controller) else { return }
        #endif
        logDevice(controller)
        guard Self.isMappable(controller) else { return }
        let id = Self.controllerID(controller)
        if controllers[id] == nil {
            controllers[id] = controller
            manager.padConnected(
                id, isExtended: controller.extendedGamepad != nil,
                optionalElements: Set(
                    Self.optionalButtons(of: controller.physicalInputProfile).map(\.element)))
        }
        installHandler(on: controller)
    }

    private func detach(_ controller: GCController) {
        let id = Self.controllerID(controller)
        guard controllers.removeValue(forKey: id) != nil else { return }
        clearHandlers(on: controller)
        manager.padDisconnected(id)
    }

    /// The handlers sit on the elements, not on the profile. The
    /// typed profile handlers (`GCExtendedGamepad.valueChangedHandler`
    /// and `GCPhysicalInputProfile.valueDidChangeHandler`) never fire
    /// for a snapshot controller, and an 8BitDo FlipPad that reaches
    /// iOS as a `GCMicroGamepad` with 18 elements gave Empo no input
    /// through them, while Delta read the same pad with element
    /// handlers (issue #140).
    ///
    /// Each handler feeds the value it received. The framework queues
    /// handlers on `handlerQueue` asynchronously, so a handler that
    /// re-reads the element sees the latest value, and a press and
    /// its release queued in one turn collapse into no edge.
    private func installHandler(on controller: GCController) {
        let controllerID = Self.controllerID(controller)
        clearHandlers(on: controller)
        controller.handlerQueue = .main
        let profile = controller.physicalInputProfile

        for entry in Self.digitalButtons(of: profile) {
            entry.button.pressedChangedHandler = { [weak manager] _, _, pressed in
                Self.onMain {
                    manager?.feedButton(controllerID: controllerID, element: entry.element, pressed: pressed)
                }
            }
        }
        for entry in Self.triggers(of: profile) {
            entry.button.valueChangedHandler = { [weak manager] _, value, _ in
                Self.onMain {
                    manager?.feedButton(controllerID: controllerID, element: entry.element, value: value)
                }
            }
        }
        for entry in Self.sticks(of: profile) {
            entry.dpad.valueChangedHandler = { [weak manager] _, x, y in
                Self.onMain {
                    manager?.feedStick(controllerID: controllerID, stick: entry.element, x: x, y: y)
                }
            }
        }
        poll(controllerID: controllerID, controller: controller)
    }

    /// `handlerQueue` is the main queue for every pad this reader
    /// owns, so the hop is for a queue that other code moved.
    private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    private func clearHandlers(on controller: GCController) {
        let profile = controller.physicalInputProfile
        for entry in Self.digitalButtons(of: profile) {
            entry.button.pressedChangedHandler = nil
        }
        for entry in Self.triggers(of: profile) {
            entry.button.valueChangedHandler = nil
        }
        for entry in Self.sticks(of: profile) {
            entry.dpad.valueChangedHandler = nil
        }
    }

    /// Rejects devices with only vendor-named elements the mapper
    /// cannot use.
    private static func isMappable(_ controller: GCController) -> Bool {
        let profile = controller.physicalInputProfile
        return !digitalButtons(of: profile).isEmpty || !triggers(of: profile).isEmpty
            || !sticks(of: profile).isEmpty
    }

    private typealias NamedButton = (element: String, button: GCControllerButtonInput)

    /// The GCInput constants are the same strings on every profile, so
    /// the reducer, the resolved map, and the remap UI see one
    /// vocabulary for all controller classes.
    private static let profileButtonElements: [(name: String, element: String)] = [
        (GCInputButtonA, "a"), (GCInputButtonB, "b"),
        (GCInputButtonX, "x"), (GCInputButtonY, "y"),
        (GCInputLeftShoulder, "leftshoulder"), (GCInputRightShoulder, "rightshoulder"),
        (GCInputButtonMenu, "start"), (GCInputButtonOptions, "back"),
        (GCInputButtonHome, "guide"),
        (GCInputLeftThumbstickButton, "leftstick"), (GCInputRightThumbstickButton, "rightstick"),
    ]

    private static func digitalButtons(of profile: GCPhysicalInputProfile) -> [NamedButton] {
        var buttons: [NamedButton] = profileButtonElements.compactMap { entry in
            profile.buttons[entry.name].map { (entry.element, $0) }
        }
        if let dpad = profile.dpads[GCInputDirectionPad] {
            buttons += [
                ("dpup", dpad.up), ("dpdown", dpad.down), ("dpleft", dpad.left), ("dpright", dpad.right),
            ]
        }
        return buttons + optionalButtons(of: profile)
    }

    /// The typed accessors come first. The header does not promise
    /// that a DualSense keys its touchpad button under the DualShock
    /// name.
    private static func optionalButtons(of profile: GCPhysicalInputProfile) -> [NamedButton] {
        if let xbox = profile as? GCXboxGamepad {
            return [
                ("paddle1", xbox.paddleButton1), ("paddle2", xbox.paddleButton2),
                ("paddle3", xbox.paddleButton3), ("paddle4", xbox.paddleButton4),
            ].compactMap { element, button in button.map { (element, $0) } }
        }
        if let dualSense = profile as? GCDualSenseGamepad {
            return [("touchpad", dualSense.touchpadButton)]
        }
        let named: [(name: String, element: String)] = [
            (GCInputXboxPaddleOne, "paddle1"), (GCInputXboxPaddleTwo, "paddle2"),
            (GCInputXboxPaddleThree, "paddle3"), (GCInputXboxPaddleFour, "paddle4"),
            (GCInputDualShockTouchpadButton, "touchpad"),
        ]
        return named.compactMap { entry in profile.buttons[entry.name].map { (entry.element, $0) } }
    }

    private static func triggers(of profile: GCPhysicalInputProfile) -> [NamedButton] {
        [(GCInputLeftTrigger, "lefttrigger"), (GCInputRightTrigger, "righttrigger")]
            .compactMap { name, element in profile.buttons[name].map { (element, $0) } }
    }

    private static func sticks(
        of profile: GCPhysicalInputProfile
    ) -> [(element: String, dpad: GCControllerDirectionPad)] {
        [(GCInputLeftThumbstick, "left"), (GCInputRightThumbstick, "right")]
            .compactMap { name, element in profile.dpads[name].map { (element, $0) } }
    }

    /// Reads the state a controller holds right now. Only the elements
    /// the hardware exposes get fed. Absent names stay untouched so
    /// the reducer never sees false releases.
    private func poll(controllerID: String, controller: GCController) {
        let profile = controller.physicalInputProfile
        for entry in Self.digitalButtons(of: profile) {
            manager.feedButton(
                controllerID: controllerID, element: entry.element, pressed: entry.button.isPressed)
        }
        for entry in Self.triggers(of: profile) {
            manager.feedButton(controllerID: controllerID, element: entry.element, value: entry.button.value)
        }
        for entry in Self.sticks(of: profile) {
            manager.feedStick(
                controllerID: controllerID, stick: entry.element,
                x: entry.dpad.xAxis.value, y: entry.dpad.yAxis.value)
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#if DEBUG
import Foundation
#if os(iOS)
import GameController
#endif

/// A UI test sets `EMPO_UITEST_CONTROLLER` to `virtual` to play with a
/// virtual extended gamepad, or to `none` to play with no controller.
/// On the Mac, `unmapped` gives a virtual joystick that SDL does not
/// know, for the controller setup in Settings.
/// The test drives the virtual pad with Darwin notifications named
/// `sh.mateo.empo.uitest.pad.<command>`, one per entry in `commands`.
///
/// Every simulator publishes an MFi gamepad of its own: `backboardd`
/// creates the HID service `com.apple.SimulatorHID.GamePadService` at
/// boot, and GameController shows it as a connected `GCController`.
/// No setting removes it, so in both modes the app ignores every
/// controller except the virtual one.
///
/// iOS: GameController never lists `GCController.withExtendedGamepad()`
/// in `GCController.controllers()` or posts its connection, so this
/// type does both. macOS: the app reads pads through SDL, and the
/// virtual pad is an SDL virtual joystick.
@MainActor
enum UITestVirtualController {
    private static let mode = ProcessInfo.processInfo.environment["EMPO_UITEST_CONTROLLER"]

    private static let prefix = "sh.mateo.empo.uitest.pad."

    private enum Command {
        case buttonA(pressed: Bool)
        case leftStick(x: Float, y: Float)
    }

    /// The commands of one entry run in one main thread turn, so a
    /// press and its release reach the app together.
    private static let commands: [String: [Command]] = [
        "a.down": [.buttonA(pressed: true)],
        "a.up": [.buttonA(pressed: false)],
        "stick.right": [.leftStick(x: 1, y: 0)],
        "stick.upright": [.leftStick(x: 0.7, y: 0.7)],
        "stick.center": [.leftStick(x: 0, y: 0)],
        "stick.tap": [.leftStick(x: 1, y: 0), .leftStick(x: 0, y: 0)],
    ]

    static func connectIfRequested() {
        guard mode == "virtual" || (isMac && mode == "unmapped"), !isConnected else { return }
        connect()
        for name in Array(commands.keys) + ["disconnect"] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), nil,
                padCommandCallback,
                (prefix + name) as CFString, nil, .deliverImmediately)
        }
    }

    fileprivate static func run(_ notification: String) {
        guard isConnected else { return }
        let name = String(notification.dropFirst(prefix.count))
        if name == "disconnect" {
            disconnect()
        } else if let commands = commands[name] {
            commands.forEach(apply)
        }
    }

    #if os(iOS)
    private static let isMac = false
    private(set) static var controller: GCController?

    private static var isConnected: Bool { controller != nil }

    static func admits(_ candidate: GCController) -> Bool {
        mode == nil || candidate === controller
    }

    private static func connect() {
        let pad = GCController.withExtendedGamepad()
        controller = pad
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: pad)
    }

    private static func disconnect() {
        guard let controller else { return }
        Self.controller = nil
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: controller)
    }

    private static func apply(_ command: Command) {
        guard let pad = controller?.extendedGamepad else { return }
        switch command {
        case .buttonA(let pressed):
            pad.buttonA.setValue(pressed ? 1 : 0)
        case .leftStick(let x, let y):
            pad.leftThumbstick.setValueForXAxis(x, yAxis: y)
        }
    }
    #else
    private static let isMac = true
    private static var joystickID: SDL_JoystickID = 0
    private static var joystick: OpaquePointer?

    private static var isConnected: Bool { joystick != nil }

    static func admits(_ candidate: SDL_JoystickID) -> Bool {
        mode == nil || (joystickID != 0 && candidate == joystickID)
    }

    /// A virtual pad of type gamepad with no button or axis mask gets
    /// an SDL mapping where button and axis numbers are the gamepad
    /// button and axis numbers. A pad of another type gets no mapping.
    private static func connect() {
        _ = SDLControllers.shared
        var desc = SDL_VirtualJoystickDesc()
        // What the SDL_INIT_INTERFACE macro does. Swift cannot call it.
        desc.version = UInt32(MemoryLayout<SDL_VirtualJoystickDesc>.size)
        desc.type = UInt16(
            (mode == "unmapped" ? SDL_JOYSTICK_TYPE_UNKNOWN : SDL_JOYSTICK_TYPE_GAMEPAD).rawValue)
        desc.naxes = UInt16(SDL_GAMEPAD_AXIS_COUNT.rawValue)
        desc.nbuttons = UInt16(SDL_GAMEPAD_BUTTON_COUNT.rawValue)
        // SDL copies the name.
        joystickID = "Empo UI Test Pad".withCString { name in
            desc.name = name
            return SDL_AttachVirtualJoystick(&desc)
        }
        joystick = SDL_OpenJoystick(joystickID)
        // SDL takes the first value of an axis as its rest value. A
        // virtual joystick sends a value only when it changes.
        let triggers = [SDL_GAMEPAD_AXIS_LEFT_TRIGGER, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER].map {
            Int32($0.rawValue)
        }
        for axis in 0..<Int32(desc.naxes) {
            SDL_SetJoystickVirtualAxis(
                joystick, axis, triggers.contains(axis) ? Int16(SDL_JOYSTICK_AXIS_MIN) : 0)
        }
        SDL_UpdateJoysticks()
    }

    private static func disconnect() {
        SDL_CloseJoystick(joystick)
        joystick = nil
        SDL_DetachVirtualJoystick(joystickID)
    }

    private static func apply(_ command: Command) {
        switch command {
        case .buttonA(let pressed):
            SDL_SetJoystickVirtualButton(joystick, Int32(SDL_GAMEPAD_BUTTON_SOUTH.rawValue), pressed)
        case .leftStick(let x, let y):
            // SDL's y axis grows down.
            SDL_SetJoystickVirtualAxis(
                joystick, Int32(SDL_GAMEPAD_AXIS_LEFTX.rawValue), Int16(x * Float(SDL_JOYSTICK_AXIS_MAX)))
            SDL_SetJoystickVirtualAxis(
                joystick, Int32(SDL_GAMEPAD_AXIS_LEFTY.rawValue), Int16(-y * Float(SDL_JOYSTICK_AXIS_MAX)))
        }
        // A virtual joystick keeps only its newest values until SDL
        // reads it. The read puts this command in the event queue, as
        // SDL does with each report of a real pad.
        SDL_UpdateJoysticks()
    }
    #endif
}

private func padCommandCallback(
    _: CFNotificationCenter?, _: UnsafeMutableRawPointer?, name: CFNotificationName?,
    _: UnsafeRawPointer?, _: CFDictionary?
) {
    guard let name = name?.rawValue as String? else { return }
    // The Darwin center calls back on the main thread.
    MainActor.assumeIsolated { UITestVirtualController.run(name) }
}
#endif

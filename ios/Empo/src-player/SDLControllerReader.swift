// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit

/// Reads controllers through SDL for `ControllerInputManager` on the Mac.
@MainActor
final class SDLControllerReader {
    private unowned let manager: ControllerInputManager
    private var gamepads: [SDL_JoystickID: OpaquePointer] = [:]
    /// The value of each axis as the events so far give it. The pad's
    /// state can be newer than the event, and a press and its release
    /// in one pump would then give no press.
    private var axes: [SDL_JoystickID: [SDL_GamepadAxis: Int16]] = [:]
    private var listener: UUID?

    init(manager: ControllerInputManager) {
        self.manager = manager
    }

    func start() {
        listener = SDLControllers.shared.addListener { [weak self] event in self?.handle(event) }
        SDLControllers.connected(gamepadsOnly: true).forEach(open)
    }

    func stop() {
        if let listener {
            SDLControllers.shared.removeListener(listener)
        }
        listener = nil
        for gamepad in gamepads.values {
            SDL_CloseGamepad(gamepad)
        }
        gamepads.removeAll()
        axes.removeAll()
    }

    func pollAll() {
        for id in gamepads.keys {
            poll(id)
        }
    }

    private func open(_ id: SDL_JoystickID) {
        guard listener != nil, gamepads[id] == nil, SDLControllers.isShown(id),
            let gamepad = SDL_OpenGamepad(id)
        else { return }
        gamepads[id] = gamepad
        logDevice(id, gamepad: gamepad)
        manager.padConnected(
            String(id), isExtended: SDL_GamepadHasAxis(gamepad, SDL_GAMEPAD_AXIS_LEFTX),
            optionalElements: SDLControllers.optionalElements(of: gamepad))
        poll(id)
    }

    private func close(_ id: SDL_JoystickID) {
        guard let gamepad = gamepads.removeValue(forKey: id) else { return }
        SDL_CloseGamepad(gamepad)
        axes[id] = nil
        manager.padDisconnected(String(id))
    }

    private func logDevice(_ id: SDL_JoystickID, gamepad: OpaquePointer) {
        guard let log = manager.deviceLogHandler else { return }
        let mapping = SDL_GetGamepadMapping(gamepad)
        defer { SDL_free(mapping) }
        log(
            """
            controller connected: \(SDL_GetGamepadName(gamepad).map { String(cString: $0) } ?? "unnamed") \
            id=\(id) \
            vendor=\(String(format: "0x%04x", SDL_GetGamepadVendor(gamepad))) \
            product=\(String(format: "0x%04x", SDL_GetGamepadProduct(gamepad))) \
            mapping=\(mapping.map { String(cString: $0) } ?? "none")
            """
        )
    }

    private func handle(_ event: SDL_Event) {
        switch event.type {
        case SDL_EVENT_GAMEPAD_ADDED.rawValue:
            open(event.gdevice.which)
        case SDL_EVENT_GAMEPAD_REMOVED.rawValue:
            close(event.gdevice.which)
        case SDL_EVENT_GAMEPAD_REMAPPED.rawValue:
            // SDL sends no release for a control that the new mapping
            // drops. The close releases each held control.
            close(event.gdevice.which)
            open(event.gdevice.which)
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN.rawValue, SDL_EVENT_GAMEPAD_BUTTON_UP.rawValue:
            // The poll when the app becomes active catches up.
            guard SDLControllers.shared.isAppActive(), gamepads[event.gbutton.which] != nil,
                let element = Self.name(SDL_GamepadButton(Int32(event.gbutton.button)))
            else { return }
            manager.feedButton(
                controllerID: String(event.gbutton.which), element: element, pressed: event.gbutton.down)
        case SDL_EVENT_GAMEPAD_AXIS_MOTION.rawValue:
            guard SDLControllers.shared.isAppActive(), gamepads[event.gaxis.which] != nil else { return }
            let axis = SDL_GamepadAxis(Int32(event.gaxis.axis))
            axes[event.gaxis.which, default: [:]][axis] = event.gaxis.value
            feedAxis(axis, of: event.gaxis.which)
        default:
            break
        }
    }

    private static func name(_ button: SDL_GamepadButton) -> String? {
        SDL_GetGamepadStringForButton(button).map { String(cString: $0) }
    }

    /// Reads the state a controller holds right now. Only the elements
    /// the pad has get fed, so the reducer never sees false releases.
    private func poll(_ id: SDL_JoystickID) {
        guard SDLControllers.shared.isAppActive(), let gamepad = gamepads[id] else { return }
        for raw in 0..<SDL_GAMEPAD_BUTTON_COUNT.rawValue {
            let button = SDL_GamepadButton(raw)
            guard SDL_GamepadHasButton(gamepad, button), let element = Self.name(button) else { continue }
            manager.feedButton(
                controllerID: String(id), element: element, pressed: SDL_GetGamepadButton(gamepad, button))
        }
        let present = (0..<SDL_GAMEPAD_AXIS_COUNT.rawValue).map { SDL_GamepadAxis($0) }
            .filter { SDL_GamepadHasAxis(gamepad, $0) }
        axes[id] = Dictionary(uniqueKeysWithValues: present.map { ($0, SDL_GetGamepadAxis(gamepad, $0)) })
        for axis in present {
            feedAxis(axis, of: id)
        }
    }

    private func feedAxis(_ axis: SDL_GamepadAxis, of id: SDL_JoystickID) {
        guard let gamepad = gamepads[id] else { return }
        let controllerID = String(id)
        func value(_ other: SDL_GamepadAxis) -> Float {
            let raw = axes[id]?[other] ?? SDL_GetGamepadAxis(gamepad, other)
            return max(-1, Float(raw) / Float(SDL_JOYSTICK_AXIS_MAX))
        }
        switch axis {
        case SDL_GAMEPAD_AXIS_LEFTX, SDL_GAMEPAD_AXIS_LEFTY:
            // SDL's y axis grows down.
            manager.feedStick(
                controllerID: controllerID, stick: "left",
                x: value(SDL_GAMEPAD_AXIS_LEFTX), y: -value(SDL_GAMEPAD_AXIS_LEFTY))
        case SDL_GAMEPAD_AXIS_RIGHTX, SDL_GAMEPAD_AXIS_RIGHTY:
            manager.feedStick(
                controllerID: controllerID, stick: "right",
                x: value(SDL_GAMEPAD_AXIS_RIGHTX), y: -value(SDL_GAMEPAD_AXIS_RIGHTY))
        case SDL_GAMEPAD_AXIS_LEFT_TRIGGER, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER:
            guard let element = SDL_GetGamepadStringForAxis(axis).map({ String(cString: $0) }) else { return }
            manager.feedButton(controllerID: controllerID, element: element, value: value(axis))
        default:
            break
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameController
import GameProbe

/// Turns game controller buttons into the keys of Empo's default
/// controller map, and into its actions.
@MainActor
final class ControllerInput {
    private let pressKey: (Int32, Bool) -> Void
    private let runAction: (String) -> Void
    private let map = BindingResolver.resolveRuntime().elements
    private var heldElements: Set<String> = []
    // The pad and the stick can both hold an arrow key.
    private var keyHolds: [Int32: Int] = [:]
    private var observer: NSObjectProtocol?

    init(pressKey: @escaping (Int32, Bool) -> Void, runAction: @escaping (String) -> Void) {
        self.pressKey = pressKey
        self.runAction = runAction
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(controller) }
        }
        GCController.controllers().forEach(attach)
    }

    func releaseAll() {
        for element in heldElements {
            set(element, pressed: false)
        }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let buttons: [(GCControllerButtonInput?, String)] = [
            (pad.dpad.up, "dpup"), (pad.dpad.down, "dpdown"), (pad.dpad.left, "dpleft"),
            (pad.dpad.right, "dpright"), (pad.buttonA, "a"), (pad.buttonB, "b"), (pad.buttonX, "x"),
            (pad.buttonY, "y"), (pad.leftShoulder, "leftshoulder"), (pad.rightShoulder, "rightshoulder"),
            (pad.leftThumbstickButton, "leftstick"), (pad.rightThumbstickButton, "rightstick"),
            (pad.buttonMenu, "start"), (pad.buttonOptions, "back"),
        ]
        for (button, element) in buttons {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.set(element, pressed: pressed) }
            }
        }
        // GameController counts y up, the map counts it down.
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                self?.set("-leftx", pressed: x < -0.5)
                self?.set("+leftx", pressed: x > 0.5)
                self?.set("-lefty", pressed: y > 0.5)
                self?.set("+lefty", pressed: y < -0.5)
            }
        }
    }

    private func set(_ element: String, pressed: Bool) {
        guard heldElements.contains(element) != pressed else { return }
        if pressed {
            heldElements.insert(element)
        } else {
            heldElements.remove(element)
        }
        switch map[element] {
        case .key(let scancode):
            let holds = keyHolds[scancode, default: 0] + (pressed ? 1 : -1)
            keyHolds[scancode] = holds
            if pressed, holds == 1 { pressKey(scancode, true) }
            if !pressed, holds == 0 { pressKey(scancode, false) }
        case .action(let id):
            if pressed { runAction(id) }
        case .unbound, nil:
            break
        }
    }
}

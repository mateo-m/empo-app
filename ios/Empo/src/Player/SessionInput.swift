// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// The controller and keyboard input of a session, and the overlay rule
/// that both feed. A change to both managers, such as start, stop,
/// bindings, or a remap listener, is one call here.
@MainActor
final class SessionInput {
    /// Gets the presses while a remap screen shows. No press goes to
    /// the game while a listener is set.
    struct RemapListener {
        var elementPressed: (String) -> Void
        var controllersChanged: () -> Void
        var keyPressed: (String) -> Void
    }

    let controller = ControllerInputManager()
    let keyboard = KeyboardInputManager()
    private let overlay = OverlayVisibilityController()

    init() {
        controller.overlay = overlay
        keyboard.overlay = overlay
    }

    var actionHandler: ((String, Bool) -> Bool)? {
        didSet {
            controller.actionHandler = actionHandler
            keyboard.actionHandler = actionHandler
        }
    }

    var deviceLogHandler: ((String) -> Void)? {
        didSet {
            controller.deviceLogHandler = deviceLogHandler
            keyboard.deviceLogHandler = deviceLogHandler
        }
    }

    /// True while the game asks for text. The keyboard passes keys
    /// through unmapped, so the player types what they typed.
    var textInputActive: Bool {
        get { keyboard.textInputActive }
        set { keyboard.textInputActive = newValue }
    }

    var remapListener: RemapListener? {
        didSet {
            controller.suppressInjection = remapListener != nil
            keyboard.suppressInjection = remapListener != nil
            controller.elementActivityHandler = remapListener?.elementPressed
            controller.connectionHandler = remapListener?.controllersChanged
            keyboard.keyActivityHandler = remapListener?.keyPressed
        }
    }

    var hasSeenPhysicalInput: Bool {
        controller.hasHadControllerThisSession || keyboard.hasHadKeyboardThisSession
    }

    func start(overlayHidden: Binding<Bool>, editMode: @escaping () -> Bool) {
        overlay.bind(hidden: overlayHidden, editMode: editMode)
        controller.start()
        keyboard.start()
    }

    func stop() {
        controller.stop()
        keyboard.stop()
        overlay.unbind()
    }

    func applyBindings(container: GameContainer?, manifest: BindingMap?) {
        let runtime = BindingResolver.resolveRuntime(
            layers: BindingLayers.overrideLayers(for: container, manifest: manifest))
        controller.updateResolvedMap(runtime.elements)
        keyboard.updateResolvedMap(runtime.keys)
    }

    func noteManualOverlayToggle() {
        overlay.update { $0.noteManualToggle() }
    }
}

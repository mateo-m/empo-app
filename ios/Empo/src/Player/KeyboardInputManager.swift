import Foundation
import GameController
import GameProbe
import SwiftUI

/// Host-side hardware keyboard input (SPEC §10.3).
///
/// A controller in keyboard mode — the 8BitDo Micro and its kin — is
/// a Bluetooth keyboard to iOS, never a `GCController`. Reading the
/// keyboard here puts those pads on the same binding layers as every
/// other controller, so one set of binds serves them all.
///
/// The manager owns the keyboard while a session runs: it takes the
/// `keyChangedHandler` slot, which holds exactly one handler, so the
/// engine's SDL never sees a key and no press can arrive twice. A key
/// with no binding is injected unchanged, which keeps typing and the
/// engine hotkeys working.
@MainActor
final class KeyboardInputManager {
    /// Dispatches action targets: (action id, pressed).
    var actionHandler: ((String, Bool) -> Void)?

    /// Runs on physical key press edges (listen mode for the remap
    /// UI). The argument is the W3C key code.
    var keyActivityHandler: ((String) -> Void)?

    /// Reports keyboard connects to `controls.json.log`. A pad in
    /// keyboard mode arrives here, not through GameController, so a
    /// bug report needs the line to tell the two apart.
    var deviceLogHandler: ((String) -> Void)?

    /// When true, edges neither inject keys nor dispatch actions (the
    /// remap screen is frontmost). Keys held at that moment release,
    /// because their release edges no longer reach the engine.
    var suppressInjection = false {
        didSet {
            if suppressInjection, !oldValue {
                releaseAllHeldKeys()
            }
        }
    }

    /// True once a hardware keyboard has connected during this session.
    private(set) var hasHadKeyboardThisSession = false

    /// Set while the game asks for text input. The player is typing,
    /// so every key passes through unmapped.
    var textInputActive = false {
        didSet {
            if textInputActive, !oldValue {
                releaseAllHeldKeys()
            }
        }
    }

    private var sessionActive = false
    private var resolvedMap: [Int32: BindingResolver.ResolvedTarget] = [:]
    /// source scancode -> injected scancode, so a release repeats the
    /// press-time decision even if the map changed meanwhile.
    private var pressedKeyScancode: [Int32: Int32] = [:]
    private var pressedKeyAction: [Int32: String] = [:]
    private var heldScancodes: [Int32: Int] = [:]
    private var overlayManualOverride = false

    private var overlayHiddenBinding: Binding<Bool>?
    private var editModeBinding: Binding<Bool>?

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    /// Atomically swap the merged key map. Keys held mid-press keep
    /// their press-time target until release.
    func updateResolvedMap(_ map: [Int32: BindingResolver.ResolvedTarget]) {
        resolvedMap = map
    }

    func start(overlayHidden: Binding<Bool>, editMode: Binding<Bool>) {
        stop()
        sessionActive = true
        overlayHiddenBinding = overlayHidden
        editModeBinding = editMode
        overlayManualOverride = false
        hasHadKeyboardThisSession = false

        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let keyboard = notification.object as? GCKeyboard
            Task { @MainActor in
                self?.attach(keyboard)
            }
        }

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.detach()
            }
        }

        attach(GCKeyboard.coalesced)
    }

    func stop() {
        sessionActive = false
        releaseAllHeldKeys()

        if let connectObserver {
            NotificationCenter.default.removeObserver(connectObserver)
        }
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
        connectObserver = nil
        disconnectObserver = nil

        // Hand the keys back as themselves. Clearing the slot would
        // leave the keyboard dead until it reconnects, because SDL
        // only claims the slot on connect and we took it from there.
        installPassThroughHandler()

        overlayHiddenBinding = nil
        editModeBinding = nil
        overlayManualOverride = false
        textInputActive = false
    }

    /// The player calls this when they toggle overlay visibility by
    /// hand, so the first-keypress auto-hide does not fight them.
    func noteManualOverlayToggle() {
        overlayManualOverride = true
    }

    private func attach(_ keyboard: GCKeyboard?) {
        guard sessionActive, let input = keyboard?.keyboardInput else { return }
        if !hasHadKeyboardThisSession {
            deviceLogHandler?("keyboard connected: \(keyboard?.vendorName ?? "unnamed")")
        }
        hasHadKeyboardThisSession = true

        // SDL claims this same slot when the engine starts, and again
        // on every keyboard connect. The slot holds one handler, so
        // taking it makes the host the only reader and nothing can
        // arrive twice. Our connect observer hops through the main
        // actor, which puts it after SDL's synchronous one. If the
        // host ever lost the race, SDL would deliver plain keys to
        // the game: unmapped, but never dead.
        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            // SDL points the profile's handler queue at a background
            // queue, and that queue outlives its handler.
            Task { @MainActor in
                self?.handle(keyCode: keyCode, pressed: pressed)
            }
        }
    }

    private func detach() {
        releaseAllHeldKeys()
    }

    private func installPassThroughHandler() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = {
            _, _, keyCode, pressed in
            let scancode = Int32(keyCode.rawValue)
            Task { @MainActor in
                EngineSessionCoordinator.shared.injectKey(scancode: scancode, pressed: pressed)
            }
        }
    }

    private func handle(keyCode: GCKeyCode, pressed: Bool) {
        guard sessionActive else { return }
        let source = Int32(keyCode.rawValue)

        if pressed {
            if let code = KeyCodeTable.code(for: source) {
                keyActivityHandler?(code)
            }
            applyAutoOverlayVisibility()
        }

        guard !suppressInjection else { return }

        // While the game is taking text, the keyboard is a keyboard.
        if textInputActive {
            EngineSessionCoordinator.shared.injectKey(scancode: source, pressed: pressed)
            return
        }

        if pressed {
            switch resolvedMap[source] {
            case .key(let scancode):
                press(source: source, scancode: scancode)
            case .action(let name):
                pressedKeyAction[source] = name
                actionHandler?(name, true)
            case .unbound:
                break
            case nil:
                // No binding: the key is itself.
                press(source: source, scancode: source)
            }
        } else {
            if let action = pressedKeyAction.removeValue(forKey: source) {
                actionHandler?(action, false)
                return
            }
            guard let scancode = pressedKeyScancode.removeValue(forKey: source) else { return }
            release(scancode: scancode)
        }
    }

    /// Two physical keys can map to one game key. The engine sees a
    /// press on the first and a release on the last.
    private func press(source: Int32, scancode: Int32) {
        pressedKeyScancode[source] = scancode
        let holders = heldScancodes[scancode, default: 0]
        heldScancodes[scancode] = holders + 1
        if holders == 0 {
            EngineSessionCoordinator.shared.injectKey(scancode: scancode, pressed: true)
        }
    }

    private func release(scancode: Int32) {
        let holders = heldScancodes[scancode, default: 0]
        if holders <= 1 {
            heldScancodes.removeValue(forKey: scancode)
            EngineSessionCoordinator.shared.injectKey(scancode: scancode, pressed: false)
        } else {
            heldScancodes[scancode] = holders - 1
        }
    }

    /// The overlay hides on the first key press, not on connect: an
    /// iPad with a Magic Keyboard attached keeps its touch controls
    /// until the player actually plays with keys.
    private func applyAutoOverlayVisibility() {
        guard !overlayManualOverride else { return }
        guard editModeBinding?.wrappedValue != true else { return }
        guard let overlayHiddenBinding, !overlayHiddenBinding.wrappedValue else { return }
        overlayHiddenBinding.wrappedValue = true
    }

    private func releaseAllHeldKeys() {
        for scancode in heldScancodes.keys {
            EngineSessionCoordinator.shared.injectKey(scancode: scancode, pressed: false)
        }
        heldScancodes.removeAll()
        pressedKeyScancode.removeAll()

        for action in pressedKeyAction.values {
            actionHandler?(action, false)
        }
        pressedKeyAction.removeAll()
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameController
import GameProbe

/// A controller in keyboard mode, such as the 8BitDo Micro, is a
/// Bluetooth keyboard to iOS, not a `GCController`. A pad in keyboard
/// mode logs a keyboard line, not a controller line.
///
/// While a session runs, the manager takes the `keyChangedHandler`
/// slot, which holds one handler, so the SDL of the engine sees no key.
/// A key with no binding goes to the game unchanged.
final class KeyboardInputManager: InputManager<Int32> {
    /// Gets the W3C key code of each physical key press.
    var keyActivityHandler: ((String) -> Void)?

    private(set) var hasHadKeyboardThisSession = false

    /// While the game asks for text, each key goes to the game unmapped.
    var textInputActive = false {
        didSet {
            if textInputActive, !oldValue {
                releaseAllHeldInputs()
            }
        }
    }

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    init(keys: HeldKeys<KeyHolder>) {
        super.init(keys: keys, source: .keyboard, holder: KeyHolder.keyboard)
    }

    convenience init() {
        self.init(keys: EngineSessionCoordinator.shared.heldKeys)
    }

    func start() {
        stop()
        sessionActive = true
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

        // After a tap on a game in its own process, iOS sends the keys
        // there, and the process sends them on to here.
        EmpoGameProcessClient.setKeyHandler { [weak self] keyCode, pressed in
            MainActor.assumeIsolated {
                self?.handle(keyCode: GCKeyCode(rawValue: keyCode), pressed: pressed)
            }
        }
    }

    func stop() {
        sessionActive = false
        releaseAllHeldInputs()

        if let connectObserver {
            NotificationCenter.default.removeObserver(connectObserver)
        }
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
        connectObserver = nil
        disconnectObserver = nil

        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        EmpoGameProcessClient.setKeyHandler(nil)
        textInputActive = false
    }

    private func attach(_ keyboard: GCKeyboard?) {
        guard sessionActive, let input = keyboard?.keyboardInput else { return }
        if !hasHadKeyboardThisSession {
            deviceLogHandler?("keyboard connected: \(keyboard?.vendorName ?? "unnamed")")
        }
        hasHadKeyboardThisSession = true

        // SDL takes this slot when the engine starts and on each
        // keyboard connect. The connect observer above goes through the
        // main actor, so it runs after the synchronous observer of SDL.
        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            // SDL points the profile's handler queue at a background
            // queue, and that queue outlives its handler.
            Task { @MainActor in
                self?.handle(keyCode: keyCode, pressed: pressed)
            }
        }
    }

    private func detach() {
        releaseAllHeldInputs()
    }

    private func handle(keyCode: GCKeyCode, pressed: Bool) {
        guard sessionActive else { return }
        let source = Int32(keyCode.rawValue)

        if pressed {
            if keyActivityHandler != nil, let code = KeyCodeTable.code(for: source) {
                keyActivityHandler?(code)
            }
            overlay?.update { $0.noteKeyPress() }
        }

        guard !suppressInjection else { return }

        if pressed {
            let target: ResolvedTarget = textInputActive ? .key(source) : resolvedMap[source] ?? .key(source)
            press(source, as: target)
        } else {
            release(source)
        }
    }
}

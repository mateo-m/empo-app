import SwiftUI

/// Invisible UIKit text field with one job: bring up the system
/// keyboard and route its text and return-key events into the
/// engine via `EngineSessionCoordinator`. The visible on-screen
/// controls (D-pad, action buttons) are plain SwiftUI now - see
/// `GameControls.swift` - so this is the only UIViewRepresentable
/// the player still needs.
struct KeyboardFieldRepresentable: UIViewRepresentable {
    var isActive: Bool
    /// Scancodes the accessory bar must hide, asked fresh on every
    /// keyboard presentation.
    var excludedScancodes: () -> Set<Int32> = { [] }
    var onActivate: (() -> Void)?

    func makeUIView(context: Context) -> TCKeyboardField {
        let field = TCKeyboardField(frame: .zero)
        field.autocorrectionType = UITextAutocorrectionType.no
        field.autocapitalizationType = UITextAutocapitalizationType.none
        field.spellCheckingType = UITextSpellCheckingType.no
        field.smartQuotesType = UITextSmartQuotesType.no
        field.smartDashesType = UITextSmartDashesType.no
        field.smartInsertDeleteType = UITextSmartInsertDeleteType.no
        field.returnKeyType = UIReturnKeyType.default
        // Opt out of every system input service. iOS runs autofill
        // heuristics on plain text fields and can flash its own
        // chrome (an autofill "Continue" pill) around keyboard
        // transitions. An empty content type turns the heuristics
        // off. The rest disables predictions, Writing Tools, and the
        // iPad shortcut bar, which have no meaning for game input.
        field.textContentType = UITextContentType(rawValue: "")
        field.inlinePredictionType = UITextInlinePredictionType.no
        field.writingToolsBehavior = UIWritingToolsBehavior.none
        field.inputAssistantItem.leadingBarButtonGroups = []
        field.inputAssistantItem.trailingBarButtonGroups = []
        // The field is invisible, but it is a real first responder
        // in the middle of the player view. Arrow keys move its text
        // selection, and the system caret and selection chrome would
        // draw mid-screen. A clear tint hides that chrome even when
        // the selection geometry overrides on TCKeyboardField are
        // bypassed by the system's own selection interaction.
        field.tintColor = UIColor.clear
        field.inputAccessoryView = KeyboardAccessoryHostView(excludedScancodes: excludedScancodes)
        field.text = " "  // keep a space so backspace works
        field.delegate = context.coordinator
        return field
    }

    func updateUIView(_ field: TCKeyboardField, context: Context) {
        // Refresh the closure before any responder change, so a new
        // presentation reads current coverage. On-screen controls
        // can hide or a controller can connect between two updates.
        (field.inputAccessoryView as? KeyboardAccessoryHostView)?
            .excludedScancodes = excludedScancodes
        if isActive && !field.isFirstResponder {
            onActivate?()
            field.becomeFirstResponder()
        } else if !isActive && field.isFirstResponder {
            // Resign first, then hand the key window back to SDL.
            // The reverse order leaves the input session open with
            // no key window, and the keyboard window can flash its
            // own UI during the dismissal. This is also the one
            // choke point every keyboard-off path goes through,
            // including the game-driven `Input.text_input` end.
            field.resignFirstResponder()
            AppWindow.setAllowKeyWindow(false)
            context.coordinator.stopTyping()
        }
    }

    static func dismantleUIView(_ field: TCKeyboardField, coordinator: Coordinator) {
        coordinator.stopTyping()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator: NSObject, UITextFieldDelegate {
        func textField(
            _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            // Backspace arrives here as an empty replacement string
            // over a non-zero range. UIKit's `deleteBackward` override
            // on TCKeyboardField doesn't fire when `text` is non-empty
            // (we prime it with a space so the on-screen Bksp key
            // stays enabled), so we must translate the empty-replacement
            // case into a scancode injection explicitly.
            let field = textField as? TCKeyboardField
            if string.isEmpty && range.length > 0 {
                type([.key(Int32(GAMECORE_SCANCODE_BACKSPACE), shifted: false)], from: field)
                textField.text = " "
                return false
            }

            // SDL text-input bridge for soft-keyboard input.
            //
            // When the engine has SDL_StartTextInput active (game
            // requested text via `Input.text_input = true`) we route
            // the typed UTF-8 string through `gamecore_pushTextInput`
            // which fabricates an `SDL_TEXTINPUT` event. EventThread
            // appends it to `textInputBuffer`, which Ruby reads via
            // `Input.gets`. This is the path Pokemon Reborn /
            // Essentials / Infinite Fusion's name-entry scenes need.
            //
            // We deliberately do NOT short-circuit the per-character
            // scancode injection below: games can do BOTH
            // `Input.gets` (text path) AND
            // `Input.triggerex?(:KEY_A)` (scancode path) in the same
            // scene. Reborn's pbFreeText listens for KEY_RETURN /
            // KEY_BACKSPACE / KEY_ESCAPE via triggerex while it
            // consumes typed characters via gets. Both paths must
            // see the input.
            //
            // When text mode is OFF (user-toggled hardware-keyboard
            // mode for a non-text scene), `gamecore_isTextInputActive`
            // returns 0 and we skip pushing text events to avoid
            // silently filling the engine's text buffer with bytes
            // nobody reads.
            let textActive = gamecore_isTextInputActive() != 0
            type(
                string.flatMap { char -> [TypedInput] in
                    let sc = scancodeForSwiftCharacter(char.utf16.first ?? 0)
                    var inputs: [TypedInput] = textActive ? [.text(String(char))] : []
                    if sc != GAMECORE_SCANCODE_UNKNOWN {
                        inputs.append(.key(sc, shifted: char.isASCII && char.isUppercase))
                    }
                    return inputs
                }, from: field)
            textField.text = " "
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            type([.key(Int32(GAMECORE_SCANCODE_RETURN), shifted: false)], from: textField as? TCKeyboardField)
            return false
        }

        private var pending: [TypedInput] = []
        private var typing = false
        private var stops = 0

        /// Drops the keys not typed yet, so a long paste can't reach the
        /// game after the keyboard closes. The key that is down goes up.
        func stopTyping() {
            pending = []
            stops += 1
        }

        /// Taps the keys one after another. Games read the keyboard
        /// once per frame, often at 40 fps or less, and see keys that
        /// overlap as one chord: Shift held for a capital turns the
        /// next letter into a capital too, and two letters in the
        /// same frame type only one.
        private func type(_ inputs: [TypedInput], from field: TCKeyboardField?) {
            // A hardware key types into this field too, and
            // KeyboardInputManager already sends its real key edges.
            // A second copy from here would release Shift while the
            // player still holds it.
            let hardware = field?.hardwareKeyTyping ?? false
            pending += inputs.filter { input in
                if case .key = input { return !hardware }
                return true
            }
            guard !typing else { return }
            typing = true
            Task { @MainActor in
                let engine = EngineSessionCoordinator.shared
                let shift = Int32(GAMECORE_SCANCODE_LSHIFT)
                while !pending.isEmpty {
                    let batch = pending
                    let stop = stops
                    pending = []
                    for input in batch where stops == stop {
                        switch input {
                        case .text(let text):
                            text.withCString { gamecore_pushTextInput($0) }
                            await Task.yield()
                        case .key(let scancode, let shifted):
                            if shifted { engine.injectKey(scancode: shift, pressed: true) }
                            engine.injectKey(scancode: scancode, pressed: true)
                            try? await Task.sleep(for: .milliseconds(50))
                            engine.injectKey(scancode: scancode, pressed: false)
                            if shifted { engine.injectKey(scancode: shift, pressed: false) }
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                    }
                }
                typing = false
            }
        }

        private func scancodeForSwiftCharacter(_ c: UInt16) -> Int32 {
            // UnicodeScalar(UInt16) returns nil for surrogate values
            // (0xD800-0xDFFF) that can be produced by emoji and other
            // astral-plane input from international keyboards. Bailing
            // out with an "unknown" scancode is fine: the engine ignores
            // unrecognized scancodes rather than crashing the app.
            guard let scalar = UnicodeScalar(c) else {
                return Int32(GAMECORE_SCANCODE_UNKNOWN)
            }
            let ch = Character(scalar)
            switch ch {
            case "a"..."z":
                return Int32(GAMECORE_SCANCODE_A) + Int32(c) - Int32(Character("a").asciiValue!)
            case "A"..."Z":
                return Int32(GAMECORE_SCANCODE_A) + Int32(c) - Int32(Character("A").asciiValue!)
            case "1"..."9":
                return Int32(GAMECORE_SCANCODE_1) + Int32(c) - Int32(Character("1").asciiValue!)
            case "0": return Int32(GAMECORE_SCANCODE_0)
            case " ": return Int32(GAMECORE_SCANCODE_SPACE)
            case "\n": return Int32(GAMECORE_SCANCODE_RETURN)
            case "\t": return Int32(GAMECORE_SCANCODE_TAB)
            case "-": return Int32(GAMECORE_SCANCODE_MINUS)
            case "=": return Int32(GAMECORE_SCANCODE_EQUALS)
            case "[": return Int32(GAMECORE_SCANCODE_LEFTBRACKET)
            case "]": return Int32(GAMECORE_SCANCODE_RIGHTBRACKET)
            case "\\": return Int32(GAMECORE_SCANCODE_BACKSLASH)
            case ";": return Int32(GAMECORE_SCANCODE_SEMICOLON)
            case "'": return Int32(GAMECORE_SCANCODE_APOSTROPHE)
            case ",": return Int32(GAMECORE_SCANCODE_COMMA)
            case ".": return Int32(GAMECORE_SCANCODE_PERIOD)
            case "/": return Int32(GAMECORE_SCANCODE_SLASH)
            case "`": return Int32(GAMECORE_SCANCODE_GRAVE)
            default: return Int32(GAMECORE_SCANCODE_UNKNOWN)
            }
        }
    }
}

private enum TypedInput {
    case text(String)
    case key(Int32, shifted: Bool)
}

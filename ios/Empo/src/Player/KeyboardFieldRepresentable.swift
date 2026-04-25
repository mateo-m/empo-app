import SwiftUI

/// Invisible UIKit text field used exclusively to bring up the
/// system keyboard and route its text and return-key events into
/// the engine via `mkxp_injectKeyEvent`. The visible on-screen
/// controls (D-pad, action buttons) are plain SwiftUI now - see
/// `GameControls.swift` - so this is the only UIViewRepresentable
/// the player still needs.
struct KeyboardFieldRepresentable: UIViewRepresentable {
    var isActive: Bool
    var onActivate: (() -> Void)?

    func makeUIView(context: Context) -> TCKeyboardField {
        let field = TCKeyboardField(frame: .zero)
        field.autocorrectionType = UITextAutocorrectionType.no
        field.autocapitalizationType = UITextAutocapitalizationType.none
        field.spellCheckingType = UITextSpellCheckingType.no
        field.smartQuotesType = UITextSmartQuotesType.no
        field.smartDashesType = UITextSmartDashesType.no
        field.returnKeyType = UIReturnKeyType.default
        field.inputAccessoryView = TCCreateKeyboardAccessoryView()
        field.text = " " // keep a space so backspace works
        field.delegate = context.coordinator
        return field
    }

    func updateUIView(_ field: TCKeyboardField, context: Context) {
        if isActive && !field.isFirstResponder {
            onActivate?()
            field.becomeFirstResponder()
        } else if !isActive && field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            // Backspace arrives here as an empty replacement string
            // over a non-zero range. UIKit's `deleteBackward` override
            // on TCKeyboardField doesn't fire when `text` is non-empty
            // (we prime it with a space so the on-screen Bksp key
            // stays enabled), so the empty-replacement case has to be
            // translated into a scancode injection explicitly.
            if string.isEmpty && range.length > 0 {
                mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_BACKSPACE), 1)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_BACKSPACE), 0)
                }
                textField.text = " "
                return false
            }

            // SDL text-input bridge for soft-keyboard input.
            //
            // When the engine has SDL_StartTextInput active (game
            // requested text via `Input.text_input = true`) we route
            // the typed UTF-8 string through `mkxp_pushTextInput`
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
            // mode for a non-text scene), `mkxp_isTextInputActive`
            // returns 0 and we skip pushing text events to avoid
            // silently filling the engine's text buffer with bytes
            // nobody reads.
            if mkxp_isTextInputActive() != 0 {
                string.withCString { mkxp_pushTextInput($0) }
            }

            for char in string {
                let c = char.utf16.first ?? 0
                let isUpper = (c >= UInt16(Character("A").asciiValue!) &&
                               c <= UInt16(Character("Z").asciiValue!))
                let sc = scancodeForSwiftCharacter(c)
                if sc == MKXP_SCANCODE_UNKNOWN { continue }

                if isUpper { mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_LSHIFT), 1) }
                mkxp_injectKeyEvent(sc, 1)
                let scancode = sc
                let upper = isUpper
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    mkxp_injectKeyEvent(scancode, 0)
                    if upper { mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_LSHIFT), 0) }
                }
            }
            textField.text = " "
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_RETURN), 1)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_RETURN), 0)
            }
            return false
        }

        private func scancodeForSwiftCharacter(_ c: UInt16) -> Int32 {
            // UnicodeScalar(UInt16) returns nil for surrogate values
            // (0xD800-0xDFFF) that can be produced by emoji and other
            // astral-plane input from international keyboards. Bailing
            // out with an "unknown" scancode is fine: the engine ignores
            // unrecognized scancodes rather than crashing the app.
            guard let scalar = UnicodeScalar(c) else {
                return Int32(MKXP_SCANCODE_UNKNOWN)
            }
            let ch = Character(scalar)
            switch ch {
            case "a"..."z":
                return Int32(MKXP_SCANCODE_A) + Int32(c) - Int32(Character("a").asciiValue!)
            case "A"..."Z":
                return Int32(MKXP_SCANCODE_A) + Int32(c) - Int32(Character("A").asciiValue!)
            case "1"..."9":
                return Int32(MKXP_SCANCODE_1) + Int32(c) - Int32(Character("1").asciiValue!)
            case "0":  return Int32(MKXP_SCANCODE_0)
            case " ":  return Int32(MKXP_SCANCODE_SPACE)
            case "\n": return Int32(MKXP_SCANCODE_RETURN)
            case "\t": return Int32(MKXP_SCANCODE_TAB)
            case "-":  return Int32(MKXP_SCANCODE_MINUS)
            case "=":  return Int32(MKXP_SCANCODE_EQUALS)
            case "[":  return Int32(MKXP_SCANCODE_LEFTBRACKET)
            case "]":  return Int32(MKXP_SCANCODE_RIGHTBRACKET)
            case "\\": return Int32(MKXP_SCANCODE_BACKSLASH)
            case ";":  return Int32(MKXP_SCANCODE_SEMICOLON)
            case "'":  return Int32(MKXP_SCANCODE_APOSTROPHE)
            case ",":  return Int32(MKXP_SCANCODE_COMMA)
            case ".":  return Int32(MKXP_SCANCODE_PERIOD)
            case "/":  return Int32(MKXP_SCANCODE_SLASH)
            case "`":  return Int32(MKXP_SCANCODE_GRAVE)
            default:   return Int32(MKXP_SCANCODE_UNKNOWN)
            }
        }
    }
}

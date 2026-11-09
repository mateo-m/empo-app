// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

struct KeyboardFieldRepresentable: UIViewRepresentable {
    var isActive: Bool
    var excludedScancodes: () -> Set<Int32> = { [] }

    func makeUIView(context: Context) -> TCKeyboardField {
        let field = TCKeyboardField(frame: .zero)
        field.autocorrectionType = UITextAutocorrectionType.no
        field.autocapitalizationType = UITextAutocapitalizationType.none
        field.spellCheckingType = UITextSpellCheckingType.no
        field.smartQuotesType = UITextSmartQuotesType.no
        field.smartDashesType = UITextSmartDashesType.no
        field.smartInsertDeleteType = UITextSmartInsertDeleteType.no
        field.returnKeyType = UIReturnKeyType.default
        // iOS runs autofill on a plain text field and can show an
        // autofill "Continue" pill when the keyboard opens or closes.
        // An empty content type stops it.
        field.textContentType = UITextContentType(rawValue: "")
        field.inlinePredictionType = UITextInlinePredictionType.no
        field.writingToolsBehavior = UIWritingToolsBehavior.none
        field.inputAssistantItem.leadingBarButtonGroups = []
        field.inputAssistantItem.trailingBarButtonGroups = []
        // Arrow keys move the text selection of the field. The system
        // selection interaction can skip the selection overrides of
        // TCKeyboardField, so a clear tint hides the caret.
        field.tintColor = UIColor.clear
        field.inputAccessoryView = KeyboardAccessoryHostView(excludedScancodes: excludedScancodes)
        field.text = " "  // keep a space so backspace works
        field.delegate = context.coordinator
        field.onDeleteBackward = { [weak field, coordinator = context.coordinator] in
            coordinator.typeBackspace(from: field)
        }
        return field
    }

    func updateUIView(_ field: TCKeyboardField, context: Context) {
        (field.inputAccessoryView as? KeyboardAccessoryHostView)?
            .excludedScancodes = excludedScancodes
        if isActive && !field.isFirstResponder {
            AppWindow.claimKey(.keyboard)
            field.becomeFirstResponder()
        } else if !isActive && field.isFirstResponder {
            // Resign first. With the key window released first, the
            // input session stays open with no key window, and the
            // keyboard window can show its own UI while it closes.
            field.resignFirstResponder()
            AppWindow.releaseKey(.keyboard)
            context.coordinator.stopTyping()
        }
    }

    static func dismantleUIView(_ field: TCKeyboardField, coordinator: Coordinator) {
        AppWindow.releaseKey(.keyboard)
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
            // UIKit calls the `deleteBackward` override only when
            // `text` is empty. The field keeps a space, so backspace
            // comes here as an empty string over a range.
            let field = textField as? TCKeyboardField
            if string.isEmpty && range.length > 0 {
                typeBackspace(from: field)
                textField.text = " "
                return false
            }

            // One scene can read the same input as text through
            // `Input.gets` and as keys through `Input.triggerex?`, for
            // example the pbFreeText name entry of Pokemon Reborn. So
            // each character goes on both paths. Text goes only while
            // the game reads text, or it fills a buffer that nothing
            // reads.
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

        func typeBackspace(from field: TCKeyboardField?) {
            let backspace = Int32(GAMECORE_SCANCODE_BACKSPACE)
            type(
                [
                    .key(
                        backspace, shifted: false,
                        hold: .milliseconds(HeldKeys<KeyHolder>.tapHoldMilliseconds))
                ], from: field)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            type([.key(Int32(GAMECORE_SCANCODE_RETURN), shifted: false)], from: textField as? TCKeyboardField)
            return false
        }

        private var pending: [TypedInput] = []
        private var typing = false
        private var stops = 0

        /// A long paste must not reach the game after the keyboard
        /// closes. The key that is down goes up.
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
            // A hardware key also types into this field, and
            // KeyboardInputManager already sends its key edges. A second
            // copy releases Shift while the player still holds it.
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
                let holder = KeyHolder.touch("softkey")
                while !pending.isEmpty {
                    let batch = pending
                    let stop = stops
                    pending = []
                    for input in batch where stops == stop {
                        switch input {
                        case .text(let text):
                            text.withCString { gamecore_pushTextInput($0) }
                            await Task.yield()
                        case .key(let scancode, let shifted, let hold):
                            if shifted { engine.holdKey(scancode: shift, by: holder) }
                            engine.holdKey(scancode: scancode, by: holder)
                            try? await Task.sleep(for: hold)
                            engine.releaseKey(scancode: scancode, by: holder)
                            if shifted { engine.releaseKey(scancode: shift, by: holder) }
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                    }
                }
                typing = false
            }
        }

        private func scancodeForSwiftCharacter(_ c: UInt16) -> Int32 {
            // UnicodeScalar(UInt16) returns nil for a surrogate value
            // (0xD800-0xDFFF), which an emoji gives.
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
    case key(Int32, shifted: Bool, hold: Duration = .milliseconds(50))
}

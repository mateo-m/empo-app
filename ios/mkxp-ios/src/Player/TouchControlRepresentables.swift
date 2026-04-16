import SwiftUI

struct DPadRepresentable: UIViewRepresentable {
    var size: CGFloat
    var editing: Bool
    var dragging: Bool

    func makeUIView(context: Context) -> TCDPadView {
        let dpad = TCDPadView(size: size)! // swiftlint:disable:this force_unwrapping
        return dpad
    }

    func updateUIView(_ dpad: TCDPadView, context: Context) {
        dpad.editing = editing
        dpad.dragging = dragging
    }
}

struct ActionButtonRepresentable: UIViewRepresentable {
    var label: String
    var scancode: Int32
    var buttonSize: CGFloat
    var editing: Bool
    var dragging: Bool

    func makeUIView(context: Context) -> TCButton {
        let btn = TCButton(label: label, scancode: scancode, size: buttonSize)! // swiftlint:disable:this force_unwrapping
        return btn
    }

    func updateUIView(_ btn: TCButton, context: Context) {
        btn.editing = editing
        btn.dragging = dragging
        if btn.label != label {
            btn.updateLabel(label)
        }
        if btn.scancode != scancode {
            btn.scancode = scancode
        }
        let currentSize = btn.bounds.size.width
        if abs(currentSize - buttonSize) > 1 {
            btn.resize(toSize: buttonSize, animated: true)
        }
    }
}

/// Invisible text field — only its keyboard + accessory bar matter.
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    mkxp_injectKeyEvent(scancode, 0)
                    if upper { mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_LSHIFT), 0) }
                }
            }
            textField.text = " "
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_RETURN), 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_RETURN), 0)
            }
            return false
        }

        private func scancodeForSwiftCharacter(_ c: UInt16) -> Int32 {
            let ch = Character(UnicodeScalar(c)!)
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

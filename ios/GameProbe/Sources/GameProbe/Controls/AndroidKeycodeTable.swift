import Foundation

public enum AndroidKeycodeTable {
    /// Android KeyEvent keycode -> W3C KeyboardEvent.code (SPEC §6 vocabulary).
    /// nil when the keycode has no equivalent in the §6 table.
    public static func w3cCode(for androidKeycode: Int) -> String? {
        mapping[androidKeycode]
    }

    /// Every Android keycode mapped by this table (for tests).
    public static var allMappedKeycodes: [Int] {
        mapping.keys.sorted()
    }

    private static let mapping: [Int: String] = {
        var table: [Int: String] = [:]

        for digit in 0 ... 9 {
            table[7 + digit] = "Digit\(digit)"
        }

        table[19] = "ArrowUp"
        table[20] = "ArrowDown"
        table[21] = "ArrowLeft"
        table[22] = "ArrowRight"
        table[23] = "Enter"

        for offset in 0 ... 25 {
            let letter = Character(UnicodeScalar(65 + offset)!)
            table[29 + offset] = "Key\(letter)"
        }

        table[55] = "Comma"
        table[56] = "Period"
        table[57] = "AltLeft"
        table[58] = "AltRight"
        table[59] = "ShiftLeft"
        table[60] = "ShiftRight"
        table[61] = "Tab"
        table[62] = "Space"
        table[66] = "Enter"
        table[67] = "Backspace"
        table[68] = "Backquote"
        table[69] = "Minus"
        table[70] = "Equal"
        table[71] = "BracketLeft"
        table[72] = "BracketRight"
        table[73] = "Backslash"
        table[74] = "Semicolon"
        table[75] = "Quote"
        table[76] = "Slash"
        table[92] = "PageUp"
        table[93] = "PageDown"
        table[111] = "Escape"
        table[112] = "Delete"
        table[113] = "ControlLeft"
        table[114] = "ControlRight"
        table[115] = "CapsLock"
        table[116] = "ScrollLock"
        table[117] = "MetaLeft"
        table[118] = "MetaRight"
        table[120] = "PrintScreen"
        table[121] = "Pause"
        table[122] = "Home"
        table[123] = "End"
        table[124] = "Insert"

        for functionKey in 1 ... 12 {
            table[130 + functionKey] = "F\(functionKey)"
        }

        table[143] = "NumLock"

        for digit in 0 ... 9 {
            table[144 + digit] = "Numpad\(digit)"
        }

        table[154] = "NumpadDivide"
        table[155] = "NumpadMultiply"
        table[156] = "NumpadSubtract"
        table[157] = "NumpadAdd"
        table[158] = "NumpadDecimal"
        table[160] = "NumpadEnter"

        return table
    }()
}

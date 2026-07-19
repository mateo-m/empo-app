import Foundation

public enum KeyCodeTable {
    private struct Entry {
        let code: String
        let scancode: Int32
        let displayName: String
    }

    // SPEC §6 — table order is canonical for `allCodes` and reverse lookup.
    private static let entries: [Entry] = [
        // KeyA … KeyZ → 4 … 29
        Entry(code: "KeyA", scancode: 4, displayName: "A"),
        Entry(code: "KeyB", scancode: 5, displayName: "B"),
        Entry(code: "KeyC", scancode: 6, displayName: "C"),
        Entry(code: "KeyD", scancode: 7, displayName: "D"),
        Entry(code: "KeyE", scancode: 8, displayName: "E"),
        Entry(code: "KeyF", scancode: 9, displayName: "F"),
        Entry(code: "KeyG", scancode: 10, displayName: "G"),
        Entry(code: "KeyH", scancode: 11, displayName: "H"),
        Entry(code: "KeyI", scancode: 12, displayName: "I"),
        Entry(code: "KeyJ", scancode: 13, displayName: "J"),
        Entry(code: "KeyK", scancode: 14, displayName: "K"),
        Entry(code: "KeyL", scancode: 15, displayName: "L"),
        Entry(code: "KeyM", scancode: 16, displayName: "M"),
        Entry(code: "KeyN", scancode: 17, displayName: "N"),
        Entry(code: "KeyO", scancode: 18, displayName: "O"),
        Entry(code: "KeyP", scancode: 19, displayName: "P"),
        Entry(code: "KeyQ", scancode: 20, displayName: "Q"),
        Entry(code: "KeyR", scancode: 21, displayName: "R"),
        Entry(code: "KeyS", scancode: 22, displayName: "S"),
        Entry(code: "KeyT", scancode: 23, displayName: "T"),
        Entry(code: "KeyU", scancode: 24, displayName: "U"),
        Entry(code: "KeyV", scancode: 25, displayName: "V"),
        Entry(code: "KeyW", scancode: 26, displayName: "W"),
        Entry(code: "KeyX", scancode: 27, displayName: "X"),
        Entry(code: "KeyY", scancode: 28, displayName: "Y"),
        Entry(code: "KeyZ", scancode: 29, displayName: "Z"),
        // Digit1 … Digit9, Digit0 → 30 … 38, 39
        Entry(code: "Digit1", scancode: 30, displayName: "1"),
        Entry(code: "Digit2", scancode: 31, displayName: "2"),
        Entry(code: "Digit3", scancode: 32, displayName: "3"),
        Entry(code: "Digit4", scancode: 33, displayName: "4"),
        Entry(code: "Digit5", scancode: 34, displayName: "5"),
        Entry(code: "Digit6", scancode: 35, displayName: "6"),
        Entry(code: "Digit7", scancode: 36, displayName: "7"),
        Entry(code: "Digit8", scancode: 37, displayName: "8"),
        Entry(code: "Digit9", scancode: 38, displayName: "9"),
        Entry(code: "Digit0", scancode: 39, displayName: "0"),
        Entry(code: "Enter", scancode: 40, displayName: "↵"),
        Entry(code: "Escape", scancode: 41, displayName: "Esc"),
        Entry(code: "Backspace", scancode: 42, displayName: "Backspace"),
        Entry(code: "Tab", scancode: 43, displayName: "Tab"),
        Entry(code: "Space", scancode: 44, displayName: "Space"),
        Entry(code: "Minus", scancode: 45, displayName: "-"),
        Entry(code: "Equal", scancode: 46, displayName: "="),
        Entry(code: "BracketLeft", scancode: 47, displayName: "["),
        Entry(code: "BracketRight", scancode: 48, displayName: "]"),
        Entry(code: "Backslash", scancode: 49, displayName: "\\"),
        Entry(code: "Semicolon", scancode: 51, displayName: ";"),
        Entry(code: "Quote", scancode: 52, displayName: "'"),
        Entry(code: "Backquote", scancode: 53, displayName: "`"),
        Entry(code: "Comma", scancode: 54, displayName: ","),
        Entry(code: "Period", scancode: 55, displayName: "."),
        Entry(code: "Slash", scancode: 56, displayName: "/"),
        Entry(code: "CapsLock", scancode: 57, displayName: "Caps"),
        Entry(code: "F1", scancode: 58, displayName: "F1"),
        Entry(code: "F2", scancode: 59, displayName: "F2"),
        Entry(code: "F3", scancode: 60, displayName: "F3"),
        Entry(code: "F4", scancode: 61, displayName: "F4"),
        Entry(code: "F5", scancode: 62, displayName: "F5"),
        Entry(code: "F6", scancode: 63, displayName: "F6"),
        Entry(code: "F7", scancode: 64, displayName: "F7"),
        Entry(code: "F8", scancode: 65, displayName: "F8"),
        Entry(code: "F9", scancode: 66, displayName: "F9"),
        Entry(code: "F10", scancode: 67, displayName: "F10"),
        Entry(code: "F11", scancode: 68, displayName: "F11"),
        Entry(code: "F12", scancode: 69, displayName: "F12"),
        Entry(code: "PrintScreen", scancode: 70, displayName: "PrtSc"),
        Entry(code: "ScrollLock", scancode: 71, displayName: "ScrLk"),
        Entry(code: "Pause", scancode: 72, displayName: "Pause"),
        Entry(code: "Insert", scancode: 73, displayName: "Ins"),
        Entry(code: "Home", scancode: 74, displayName: "Home"),
        Entry(code: "PageUp", scancode: 75, displayName: "PgUp"),
        Entry(code: "Delete", scancode: 76, displayName: "Del"),
        Entry(code: "End", scancode: 77, displayName: "End"),
        Entry(code: "PageDown", scancode: 78, displayName: "PgDn"),
        Entry(code: "ArrowRight", scancode: 79, displayName: "→"),
        Entry(code: "ArrowLeft", scancode: 80, displayName: "←"),
        Entry(code: "ArrowDown", scancode: 81, displayName: "↓"),
        Entry(code: "ArrowUp", scancode: 82, displayName: "↑"),
        Entry(code: "NumLock", scancode: 83, displayName: "Num"),
        Entry(code: "NumpadDivide", scancode: 84, displayName: "Num/"),
        Entry(code: "NumpadMultiply", scancode: 85, displayName: "Num*"),
        Entry(code: "NumpadSubtract", scancode: 86, displayName: "Num-"),
        Entry(code: "NumpadAdd", scancode: 87, displayName: "Num+"),
        Entry(code: "NumpadEnter", scancode: 88, displayName: "Num↵"),
        Entry(code: "Numpad1", scancode: 89, displayName: "Num1"),
        Entry(code: "Numpad2", scancode: 90, displayName: "Num2"),
        Entry(code: "Numpad3", scancode: 91, displayName: "Num3"),
        Entry(code: "Numpad4", scancode: 92, displayName: "Num4"),
        Entry(code: "Numpad5", scancode: 93, displayName: "Num5"),
        Entry(code: "Numpad6", scancode: 94, displayName: "Num6"),
        Entry(code: "Numpad7", scancode: 95, displayName: "Num7"),
        Entry(code: "Numpad8", scancode: 96, displayName: "Num8"),
        Entry(code: "Numpad9", scancode: 97, displayName: "Num9"),
        Entry(code: "Numpad0", scancode: 98, displayName: "Num0"),
        Entry(code: "NumpadDecimal", scancode: 99, displayName: "Num."),
        Entry(code: "IntlBackslash", scancode: 100, displayName: "¥"),
        Entry(code: "IntlRo", scancode: 135, displayName: "Ro"),
        Entry(code: "IntlYen", scancode: 137, displayName: "Yen"),
        Entry(code: "ControlLeft", scancode: 224, displayName: "Ctrl"),
        Entry(code: "ShiftLeft", scancode: 225, displayName: "⇧"),
        Entry(code: "AltLeft", scancode: 226, displayName: "Alt"),
        Entry(code: "MetaLeft", scancode: 227, displayName: "⌘"),
        Entry(code: "ControlRight", scancode: 228, displayName: "Ctrl"),
        Entry(code: "ShiftRight", scancode: 229, displayName: "⇧"),
        Entry(code: "AltRight", scancode: 230, displayName: "Alt"),
        Entry(code: "MetaRight", scancode: 231, displayName: "⌘"),
    ]

    private static let byCode: [String: Entry] = {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.code, $0) })
    }()

    /// W3C KeyboardEvent.code -> SDL/USB-HID scancode. nil = unknown code.
    public static func scancode(for code: String) -> Int32? {
        byCode[code]?.scancode
    }

    /// Short human label for the edit UI / auto-labels.
    public static func displayName(for code: String) -> String? {
        byCode[code]?.displayName
    }

    /// Reverse lookup (first match wins; used for migrating existing layouts to names).
    public static func code(for scancode: Int32) -> String? {
        entries.first(where: { $0.scancode == scancode })?.code
    }

    /// All codes, stable order (table order), for pickers.
    public static var allCodes: [String] {
        entries.map(\.code)
    }
}

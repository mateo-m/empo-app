import Foundation

/// Grouping for controller-remap key pickers (ticket 005).
public enum KeyCodePickerGroup: String, CaseIterable, Sendable {
    case common
    case letters
    case numbers
    case function
    case navigation
    case symbols
    case numpad
    case modifiers
}

public extension KeyCodeTable {
    /// Picker section title.
    static func pickerGroupTitle(_ group: KeyCodePickerGroup) -> String {
        switch group {
        case .common: return "Common"
        case .letters: return "Letters"
        case .numbers: return "Numbers"
        case .function: return "Function"
        case .navigation: return "Navigation"
        case .symbols: return "Symbols"
        case .numpad: return "Numpad"
        case .modifiers: return "Modifiers"
        }
    }

    /// Codes in `allCodes` order, bucketed into picker sections. Common
    /// keys ALSO appear in their natural group so e.g. the Letters
    /// section stays a complete alphabet.
    static var codesByPickerGroup: [KeyCodePickerGroup: [String]] {
        var buckets = Dictionary(uniqueKeysWithValues: KeyCodePickerGroup.allCases.map { ($0, [String]()) })
        for code in allCodes {
            if commonPickerCodes.contains(code) {
                buckets[.common, default: []].append(code)
            }
            buckets[naturalGroup(for: code), default: []].append(code)
        }
        return buckets
    }

    /// Primary group (Common wins) — drives the annotation display.
    static func pickerGroup(for code: String) -> KeyCodePickerGroup {
        commonPickerCodes.contains(code) ? .common : naturalGroup(for: code)
    }

    static func naturalGroup(for code: String) -> KeyCodePickerGroup {
        if code.hasPrefix("Key"), code.count == 4 { return .letters }
        if code.hasPrefix("Digit") { return .numbers }
        if code.hasPrefix("F"), let n = Int(code.dropFirst()), (1...12).contains(n) { return .function }
        if code.hasPrefix("Numpad") || code == "NumLock" { return .numpad }
        if modifierPickerCodes.contains(code) { return .modifiers }
        if symbolPickerCodes.contains(code) { return .symbols }
        return .navigation
    }

    private static let commonPickerCodes: Set<String> = [
        "Enter", "Space", "Escape", "KeyX", "ShiftLeft", "KeyZ",
        "KeyQ", "KeyW", "KeyA", "KeyS", "KeyD",
        "F5", "F6", "F7", "F8", "F9",
    ]

    private static let modifierPickerCodes: Set<String> = [
        "ControlLeft", "ShiftLeft", "AltLeft", "MetaLeft",
        "ControlRight", "ShiftRight", "AltRight", "MetaRight",
    ]

    private static let symbolPickerCodes: Set<String> = [
        "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash",
        "Semicolon", "Quote", "Backquote", "Comma", "Period", "Slash",
        "IntlBackslash", "IntlRo", "IntlYen",
    ]
}

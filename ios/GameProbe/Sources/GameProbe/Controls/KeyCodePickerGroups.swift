import Foundation

/// Grouping for controller-remap key pickers (ticket 005).
public enum KeyCodePickerGroup: String, CaseIterable, Sendable {
    case common
    case letters
    case numbers
    case function
    case navigation
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
        case .numpad: return "Numpad"
        case .modifiers: return "Modifiers"
        }
    }

    /// Codes in `allCodes` order, partitioned into picker groups.
    static var codesByPickerGroup: [KeyCodePickerGroup: [String]] {
        var buckets = Dictionary(uniqueKeysWithValues: KeyCodePickerGroup.allCases.map { ($0, [String]()) })
        for code in allCodes {
            buckets[pickerGroup(for: code), default: []].append(code)
        }
        return buckets
    }

    static func pickerGroup(for code: String) -> KeyCodePickerGroup {
        if commonPickerCodes.contains(code) { return .common }
        if code.hasPrefix("Key"), code.count == 4 { return .letters }
        if code.hasPrefix("Digit") { return .numbers }
        if code.hasPrefix("F"), let n = Int(code.dropFirst()), (1...12).contains(n) { return .function }
        if code.hasPrefix("Numpad") || code == "NumLock" { return .numpad }
        if modifierPickerCodes.contains(code) { return .modifiers }
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
}

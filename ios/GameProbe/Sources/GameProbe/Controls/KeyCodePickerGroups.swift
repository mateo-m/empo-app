// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

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
    static func pickerGroupTitle(_ group: KeyCodePickerGroup) -> String {
        switch group {
        case .common: return "Common keys"
        case .letters: return "Letters"
        case .numbers: return "Numbers"
        case .function: return "Function keys"
        case .navigation: return "Navigation"
        case .symbols: return "Symbols"
        case .numpad: return "Numpad"
        case .modifiers: return "Modifier keys"
        }
    }

    /// Common keys also appear in their natural group, so the Letters
    /// section keeps the full alphabet.
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

    static func pickerGroup(for code: String) -> KeyCodePickerGroup {
        commonPickerCodes.contains(code) ? .common : naturalGroup(for: code)
    }

    static func naturalGroup(for code: String) -> KeyCodePickerGroup {
        if code.hasPrefix("Key"), code.count == 4 { return .letters }
        if code.hasPrefix("Digit") { return .numbers }
        if code.hasPrefix("F"), let n = Int(code.dropFirst()), (1...12).contains(n) { return .function }
        if code.hasPrefix("Numpad") || code == "NumLock" { return .numpad }
        if let scancode = scancode(for: code), modifierScancodes.contains(scancode) {
            return .modifiers
        }
        if symbolPickerCodes.contains(code) { return .symbols }
        return .navigation
    }

    private static let commonPickerCodes: Set<String> = [
        "Enter", "Space", "Escape", "KeyX", "ShiftLeft", "KeyZ",
        "KeyQ", "KeyW", "KeyA", "KeyS", "KeyD",
        "F5", "F6", "F7", "F8", "F9",
    ]

    /// The USB HID modifier keys: Control, Shift, Alt, and Meta, left
    /// then right.
    private static let modifierScancodes: ClosedRange<Int32> = 224...231

    private static let symbolPickerCodes: Set<String> = [
        "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash",
        "Semicolon", "Quote", "Backquote", "Comma", "Period", "Slash",
        "IntlBackslash", "IntlRo", "IntlYen",
    ]
}

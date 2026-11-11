// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

enum JSONNumber {
    // JSON booleans must not pass as numbers. Type casts cannot tell
    // them apart (`NSNumber(1) is Bool` and `true as? Int` both succeed
    // on Darwin and corelibs), but `objCType` can: JSONSerialization
    // encodes booleans as "c" and integers/doubles as "q"/"d" on both
    // platforms. CF APIs are not an option. Linux Foundation lacks them.
    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return String(cString: number.objCType) == "c"
    }

    static func double(_ value: Any?) -> Double? {
        guard let value, !isBool(value) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let value, !isBool(value) else { return nil }
        if let number = value as? NSNumber { return Int(exactly: number) }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(exactly: double) }
        return nil
    }

    /// nil for a number, so that `1` does not read as true.
    static func bool(_ value: Any?) -> Bool? {
        guard let value, isBool(value) else { return nil }
        return value as? Bool
    }
}

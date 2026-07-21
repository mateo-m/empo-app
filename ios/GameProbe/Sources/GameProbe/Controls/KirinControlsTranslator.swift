import Foundation

public enum KirinControlsTranslator {
    public static let fileName = "kirin-touch-controls.json"

    public struct Translation: Sendable {
        /// nil when the file contributed nothing usable.
        public var manifest: ControlsManifest?
        /// Human-readable notes for the game's log. Never errors.
        public var notes: [String]
    }

    private static let maxFileSize = 128 * 1024
    private static let columnsPerRow = 3
    private static let maxButtons = 16

    public static func translate(data: Data) -> Translation {
        if data.count > maxFileSize {
            return Translation(manifest: nil, notes: ["file exceeds 128 KiB; ignored"])
        }

        guard let text = String(data: data, encoding: .utf8),
            let root = JSON5LiteParser.parseObject(text)
        else {
            return Translation(manifest: nil, notes: ["invalid Kirin touch controls file; ignored"])
        }

        var notes: [String] = []

        if let versionValue = root["version"] {
            if let version = asInt(versionValue) {
                if version != 1 {
                    return Translation(
                        manifest: nil,
                        notes: ["unsupported version \(version); ignored"]
                    )
                }
            }
        }

        let scale = asDouble(root["scale"]) ?? 100
        let opacityPercent = asDouble(root["opacity"]) ?? 100
        let buttonSize = clamp(56 * scale / 100, min: 40, max: 100)
        let buttonOpacity = clamp(opacityPercent / 100, min: 0.2, max: 1.0)

        var buttons: [ButtonSpec] = []

        for gridName in ["rightGrid", "leftGrid"] {
            guard let grid = root[gridName] as? [String: Any] else { continue }
            let isRightGrid = gridName == "rightGrid"
            let slots = grid["slots"] as? [Any] ?? []
            var hadInvalidSlot = false

            for (index, slot) in slots.enumerated() {
                guard slot is NSNull == false else { continue }

                guard let keycode = asInt(slot) else {
                    if !hadInvalidSlot {
                        notes.append("non-integer slot value in \(gridName); treated as empty")
                        hadInvalidSlot = true
                    }
                    continue
                }

                guard let w3c = AndroidKeycodeTable.w3cCode(for: keycode) else {
                    notes.append(
                        "slot \(index) in \(gridName): Android keycode \(keycode) has no keyboard equivalent; button dropped"
                    )
                    continue
                }

                let row = index / columnsPerRow
                let col = index % columnsPerRow
                let rowCount = (slots.count + columnsPerRow - 1) / columnsPerRow

                let x: Double
                let y: Double
                if isRightGrid {
                    x = 0.70 + Double(col) * 0.11
                    y = 0.86 - Double(rowCount - 1 - row) * 0.15
                } else {
                    x = 0.08 + Double(col) * 0.11
                    y = 0.10 + Double(row) * 0.15
                }

                buttons.append(
                    ButtonSpec(
                        label: nil,
                        key: w3c,
                        x: clamp(x, min: 0.02, max: 0.98),
                        y: clamp(y, min: 0.02, max: 0.98),
                        size: buttonSize,
                        opacity: buttonOpacity
                    )
                )
            }
        }

        if buttons.isEmpty {
            return Translation(manifest: nil, notes: notes + ["no usable buttons; ignored"])
        }

        if buttons.count > maxButtons {
            let dropped = buttons.count - maxButtons
            notes.append("\(dropped) buttons beyond Empo's 16-button limit dropped")
            buttons = Array(buttons.prefix(maxButtons))
        }

        let layout = TouchLayout(dpad: nil, buttons: buttons)
        let touch = TouchSection(portrait: layout, landscape: layout)
        let manifest = ControlsManifest(version: 1, touch: touch)

        return Translation(manifest: manifest, notes: notes)
    }

    // MARK: - JSON helpers (Linux-safe; mirrors ControlsManifestLoader)

    private static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return String(cString: number.objCType) == "c"
    }

    private static func asDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        guard !isJSONBool(value) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    private static func asInt(_ value: Any) -> Int? {
        guard !isJSONBool(value) else { return nil }
        if let number = value as? NSNumber { return Int(exactly: number) }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(exactly: double) }
        return nil
    }

    private static func clamp(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
        Swift.max(minimum, Swift.min(maximum, value))
    }
}

import Foundation

public enum JoiPlayControlsTranslator {
    public static let fileName = "gamepad.json"

    public struct Translation: Sendable {
        public var manifest: ControlsManifest?
        public var notes: [String]
    }

    private struct Slot {
        let keyField: String
        let defaultKey: String
        let label: String
        let x: Double
        let y: Double
        let baseSize: Double
    }

    private static let slots: [Slot] = [
        Slot(keyField: "cKeyCode", defaultKey: "Enter", label: "C", x: 0.86, y: 0.80, baseSize: 60),
        Slot(keyField: "bKeyCode", defaultKey: "Escape", label: "B", x: 0.73, y: 0.72, baseSize: 56),
        Slot(keyField: "aKeyCode", defaultKey: "ShiftLeft", label: "A", x: 0.63, y: 0.84, baseSize: 50),
        Slot(keyField: "xKeyCode", defaultKey: "KeyA", label: "X", x: 0.63, y: 0.60, baseSize: 44),
        Slot(keyField: "yKeyCode", defaultKey: "KeyS", label: "Y", x: 0.74, y: 0.54, baseSize: 44),
        Slot(keyField: "zKeyCode", defaultKey: "KeyD", label: "Z", x: 0.86, y: 0.60, baseSize: 44),
        Slot(keyField: "lKeyCode", defaultKey: "KeyQ", label: "L", x: 0.06, y: 0.08, baseSize: 44),
        Slot(keyField: "rKeyCode", defaultKey: "KeyW", label: "R", x: 0.94, y: 0.08, baseSize: 44),
    ]

    private static let knownKeys: Set<String> = [
        "btnOpacity", "btnScale",
        "aKeyCode", "bKeyCode", "cKeyCode", "xKeyCode", "yKeyCode", "zKeyCode", "lKeyCode", "rKeyCode",
    ]

    private static let maxFileSize = 128 * 1024

    public static func translate(data: Data) -> Translation {
        if data.count > maxFileSize {
            return Translation(manifest: nil, notes: ["file exceeds 128 KiB; ignored"])
        }

        guard let text = String(data: data, encoding: .utf8),
            let root = JSON5LiteParser.parseObject(text)
        else {
            return Translation(manifest: nil, notes: ["invalid JoiPlay gamepad file; ignored"])
        }

        guard root.keys.contains(where: { knownKeys.contains($0) }) else {
            return Translation(manifest: nil, notes: ["no JoiPlay keys; ignored"])
        }

        var notes: [String] = []

        let scalePercent: Double
        if let scaleValue = root["btnScale"] {
            if let scale = asDouble(scaleValue) {
                scalePercent = scale
            } else {
                scalePercent = 100
                notes.append("btnScale is not a number; using default 100")
            }
        } else {
            scalePercent = 100
        }

        let opacityPercent: Double
        if let opacityValue = root["btnOpacity"] {
            if let opacity = asDouble(opacityValue) {
                opacityPercent = opacity
            } else {
                opacityPercent = 100
                notes.append("btnOpacity is not a number; using default 100")
            }
        } else {
            opacityPercent = 100
        }

        let buttonOpacity = clamp(opacityPercent / 100, min: 0.2, max: 1.0)

        var buttons: [ButtonSpec] = []
        for slot in slots {
            let size = clamp(slot.baseSize * scalePercent / 100, min: 40, max: 100)
            var key = slot.defaultKey

            if let keyValue = root[slot.keyField] {
                if let keycode = asInt(keyValue) {
                    if let w3c = AndroidKeycodeTable.w3cCode(for: keycode) {
                        key = w3c
                    } else {
                        notes.append(
                            "\(slot.keyField): Android keycode \(keycode) has no keyboard equivalent; using default"
                        )
                    }
                }
            }

            buttons.append(
                ButtonSpec(
                    label: slot.label,
                    key: key,
                    x: slot.x,
                    y: slot.y,
                    size: size,
                    opacity: buttonOpacity
                )
            )
        }

        let layout = TouchLayout(dpad: nil, buttons: buttons)
        let touch = TouchSection(portrait: layout, landscape: layout)
        let manifest = ControlsManifest(version: 1, touch: touch)

        return Translation(manifest: manifest, notes: notes)
    }

    // MARK: - JSON helpers (Linux-safe; mirrors KirinControlsTranslator)

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

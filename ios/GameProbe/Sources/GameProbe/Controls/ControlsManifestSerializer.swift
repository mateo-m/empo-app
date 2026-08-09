import Foundation

/// Canonical v1 `controls.json` writer (SPEC ticket 009 item 1).
/// The output always parses through `ControlsManifestLoader.parse`
/// with zero errors.
public enum ControlsManifestSerializer {

    public struct TouchOrientedInput: Equatable, Sendable {
        public var dpadX: Double
        public var dpadY: Double
        public var dpadSize: Double
        public var dpadOpacity: Double
        public var dpadStyle: MovementStyle
        public var buttons: [TouchButtonInput]
        /// An empty list serializes as an OMITTED key on this input
        /// path (see `orientedLayout`), which means "inherit". This
        /// input feeds the legacy migration, where the user never
        /// expressed a choice about action buttons. The live save
        /// path builds `TouchLayout` directly and keeps `[]` = none.
        public var actionButtons: [TouchActionButtonInput]

        public init(
            dpadX: Double,
            dpadY: Double,
            dpadSize: Double,
            dpadOpacity: Double,
            dpadStyle: MovementStyle = .dpad,
            buttons: [TouchButtonInput],
            actionButtons: [TouchActionButtonInput] = []
        ) {
            self.dpadX = dpadX
            self.dpadY = dpadY
            self.dpadSize = dpadSize
            self.dpadOpacity = dpadOpacity
            self.dpadStyle = dpadStyle
            self.buttons = buttons
            self.actionButtons = actionButtons
        }
    }

    public struct TouchActionButtonInput: Equatable, Sendable {
        public var action: String
        public var x: Double
        public var y: Double
        public var size: Double
        public var opacity: Double

        public init(
            action: String,
            x: Double,
            y: Double,
            size: Double,
            opacity: Double
        ) {
            self.action = action
            self.x = x
            self.y = y
            self.size = size
            self.opacity = opacity
        }
    }

    public struct TouchButtonInput: Equatable, Sendable {
        public var label: String
        public var scancode: Int32
        public var x: Double
        public var y: Double
        public var size: Double
        public var opacity: Double

        public init(
            label: String,
            scancode: Int32,
            x: Double,
            y: Double,
            size: Double,
            opacity: Double
        ) {
            self.label = label
            self.scancode = scancode
            self.x = x
            self.y = y
            self.size = size
            self.opacity = opacity
        }
    }

    /// Builds a `TouchSection` from in-memory layout values (scancode-based).
    /// If a button's scancode has no W3C code, the button is dropped.
    /// `onDroppedButton` runs once per dropped button.
    public static func touchSection(
        portrait: TouchOrientedInput,
        landscape: TouchOrientedInput,
        onDroppedButton: ((String, Int32) -> Void)? = nil
    ) -> TouchSection {
        TouchSection(
            portrait: orientedLayout(portrait, onDroppedButton: onDroppedButton),
            landscape: orientedLayout(landscape, onDroppedButton: onDroppedButton)
        )
    }

    /// Returns `nil` when there is nothing to persist (no touch and no
    /// binding overrides).
    public static func serialize(
        touch: TouchSection?,
        bindings: BindingMap?
    ) -> Data? {
        let bindingEntries = bindings?.entries ?? [:]
        let hasBindings = !bindingEntries.isEmpty
        let hasTouch = touch != nil
        guard hasTouch || hasBindings else { return nil }

        var lines: [String] = []
        lines.append("{")
        lines.append("  \"version\": 1")

        if let touch {
            lines.append("  ,\"touch\": {")
            appendTouchSection(touch, into: &lines, indent: 4)
            lines.append("  }")
        }

        if hasBindings {
            lines.append("  ,\"bindings\": {")
            appendBindings(bindingEntries, into: &lines, indent: 4)
            lines.append("  }")
        }

        lines.append("}")
        lines.append("")
        return lines.joined(separator: "\n").data(using: .utf8)
    }

    // MARK: - Touch conversion

    private static func orientedLayout(
        _ input: TouchOrientedInput,
        onDroppedButton: ((String, Int32) -> Void)?
    ) -> TouchLayout {
        let dpad = DPadSpec(
            x: clampCoordinate(input.dpadX),
            y: clampCoordinate(input.dpadY),
            size: clampDPadSize(input.dpadSize),
            opacity: clampOpacity(input.dpadOpacity),
            style: input.dpadStyle
        )

        var buttons: [ButtonSpec] = []
        for button in input.buttons {
            guard let key = KeyCodeTable.code(for: button.scancode) else {
                onDroppedButton?(button.label, button.scancode)
                continue
            }
            let label = String(button.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
            buttons.append(
                ButtonSpec(
                    label: label.isEmpty ? nil : label,
                    key: key,
                    x: clampCoordinate(button.x),
                    y: clampCoordinate(button.y),
                    size: clampButtonSize(button.size),
                    opacity: clampOpacity(button.opacity)
                )
            )
        }

        var actionButtons: [ActionButtonSpec] = []
        for button in input.actionButtons {
            actionButtons.append(
                ActionButtonSpec(
                    action: button.action,
                    x: clampCoordinate(button.x),
                    y: clampCoordinate(button.y),
                    size: clampButtonSize(button.size),
                    opacity: clampOpacity(button.opacity)
                )
            )
        }

        return TouchLayout(
            dpad: dpad,
            buttons: buttons,
            actionButtons: actionButtons.isEmpty ? nil : actionButtons
        )
    }

    // MARK: - JSON emission

    private static func appendTouchSection(
        _ section: TouchSection,
        into lines: inout [String],
        indent: Int
    ) {
        let pad = String(repeating: " ", count: indent)
        var wroteOrientation = false

        if let portrait = section.portrait {
            lines.append("\(pad)\"portrait\": {")
            appendTouchLayout(portrait, into: &lines, indent: indent + 2)
            lines.append("\(pad)}")
            wroteOrientation = true
        }

        if let landscape = section.landscape {
            if wroteOrientation {
                lines.append("\(pad),\"landscape\": {")
            } else {
                lines.append("\(pad)\"landscape\": {")
            }
            appendTouchLayout(landscape, into: &lines, indent: indent + 2)
            lines.append("\(pad)}")
        }
    }

    private static func appendTouchLayout(
        _ layout: TouchLayout,
        into lines: inout [String],
        indent: Int
    ) {
        let pad = String(repeating: " ", count: indent)
        var wroteField = false

        if let dpad = layout.dpad {
            lines.append("\(pad)\"dpad\": {")
            appendDPad(dpad, into: &lines, indent: indent + 2)
            lines.append("\(pad)}")
            wroteField = true
        }

        if let buttons = layout.buttons {
            if wroteField {
                lines.append("\(pad),\"buttons\": [")
            } else {
                lines.append("\(pad)\"buttons\": [")
            }
            for (index, button) in buttons.enumerated() {
                if index > 0 {
                    lines.append("\(pad)  ,")
                } else {
                    lines.append("\(pad)  ")
                }
                appendButton(button, into: &lines, indent: indent + 4)
            }
            lines.append("\(pad)]")
            wroteField = true
        }

        // Empty emits as [] on purpose: nil means "inherit the
        // game-shipped action buttons" at load, so collapsing [] to
        // an omitted key would resurrect buttons the user deleted.
        if let actionButtons = layout.actionButtons {
            if wroteField {
                lines.append("\(pad),\"actionButtons\": [")
            } else {
                lines.append("\(pad)\"actionButtons\": [")
            }
            for (index, button) in actionButtons.enumerated() {
                if index > 0 {
                    lines.append("\(pad)  ,")
                } else {
                    lines.append("\(pad)  ")
                }
                appendActionButton(button, into: &lines, indent: indent + 4)
            }
            lines.append("\(pad)]")
        }
    }

    private static func appendActionButton(
        _ button: ActionButtonSpec,
        into lines: inout [String],
        indent: Int
    ) {
        let pad = String(repeating: " ", count: indent)
        lines.append("\(pad){")
        lines.append("\(pad)  \"action\": \(jsonString(button.action))")
        lines.append("\(pad)  ,\"x\": \(formatNumber(button.x))")
        lines.append("\(pad)  ,\"y\": \(formatNumber(button.y))")
        if let size = button.size {
            lines.append("\(pad)  ,\"size\": \(formatNumber(size))")
        }
        if let opacity = button.opacity {
            lines.append("\(pad)  ,\"opacity\": \(formatNumber(opacity))")
        }
        lines.append("\(pad)}")
    }

    private static func appendDPad(
        _ dpad: DPadSpec,
        into lines: inout [String],
        indent: Int
    ) {
        let pad = String(repeating: " ", count: indent)
        lines.append("\(pad)\"x\": \(formatNumber(dpad.x))")
        lines.append("\(pad),\"y\": \(formatNumber(dpad.y))")
        if let size = dpad.size {
            lines.append("\(pad),\"size\": \(formatNumber(size))")
        }
        if let opacity = dpad.opacity {
            lines.append("\(pad),\"opacity\": \(formatNumber(opacity))")
        }
        // Absent and "dpad" mean the same thing; only "stick" is
        // worth a line. Keeps every existing file byte-stable.
        if dpad.style != .dpad {
            lines.append("\(pad),\"style\": \(jsonString(dpad.style.rawValue))")
        }
    }

    private static func appendButton(
        _ button: ButtonSpec,
        into lines: inout [String],
        indent: Int
    ) {
        let pad = String(repeating: " ", count: indent)
        lines.append("\(pad){")
        var wroteField = false

        if let label = button.label, !label.isEmpty {
            lines.append("\(pad)  \"label\": \(jsonString(label))")
            wroteField = true
        }

        func appendField(_ name: String, value: String) {
            if wroteField {
                lines.append("\(pad)  ,\"\(name)\": \(value)")
            } else {
                lines.append("\(pad)  \"\(name)\": \(value)")
            }
            wroteField = true
        }

        appendField("key", value: jsonString(button.key))
        appendField("x", value: formatNumber(button.x))
        appendField("y", value: formatNumber(button.y))
        if let size = button.size {
            appendField("size", value: formatNumber(size))
        }
        if let opacity = button.opacity {
            appendField("opacity", value: formatNumber(opacity))
        }
        lines.append("\(pad)}")
    }

    /// Writes the bindings map in vocabulary order, so a load-save
    /// round trip stays byte stable.
    private static func appendBindings(
        _ entries: [BindingSource: ControlsTarget],
        into lines: inout [String],
        indent: Int
    ) {
        let pad = String(repeating: " ", count: indent)
        let ordered = BindingMapCoder.sourceOrder.filter { entries[$0] != nil }
        for (index, source) in ordered.enumerated() {
            guard let target = entries[source] else { continue }
            let value = target.name.map(jsonString) ?? "null"
            let separator = index > 0 ? "," : ""
            lines.append("\(pad)\(separator)\"\(source.name)\": \(value)")
        }
    }

    // MARK: - Clamping (writer-side, keeps the round trip valid)

    private static func clampCoordinate(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private static func clampButtonSize(_ value: Double) -> Double {
        min(100.0, max(40.0, value))
    }

    private static func clampDPadSize(_ value: Double) -> Double {
        min(200.0, max(100.0, value))
    }

    private static func clampOpacity(_ value: Double) -> Double {
        min(1.0, max(0.2, value))
    }

    // MARK: - Formatting

    private static func formatNumber(_ value: Double) -> String {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        if abs(rounded - rounded.rounded()) < 0.000_001 {
            return String(Int(rounded.rounded()))
        }
        var text = String(format: "%.6f", rounded)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{8}": result += "\\b"
            case "\u{c}": result += "\\f"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.append(Character(scalar))
                }
            }
        }
        result += "\""
        return result
    }
}

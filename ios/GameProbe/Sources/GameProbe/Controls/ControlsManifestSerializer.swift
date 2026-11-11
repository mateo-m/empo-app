// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum ControlsManifestSerializer {

    public static func serialize(
        touch: TouchSection?,
        bindings: BindingMap?
    ) -> Data? {
        let bindingEntries = bindings?.entries ?? [:]
        guard touch != nil || !bindingEntries.isEmpty else { return nil }
        return document(touch: touch, bindingEntries: bindingEntries)
    }

    public static func serialize(_ touch: TouchSection, bindings: BindingMap? = nil) -> Data {
        document(touch: touch, bindingEntries: bindings?.entries ?? [:])
    }

    private static func document(
        touch: TouchSection?,
        bindingEntries: [BindingSource: ControlsTarget]
    ) -> Data {
        var lines: [String] = []
        lines.append("{")
        lines.append("  \"version\": 1")

        if let touch {
            lines.append("  ,\"touch\": {")
            appendTouchSection(touch, into: &lines, indent: 4)
            lines.append("  }")
        }

        if !bindingEntries.isEmpty {
            lines.append("  ,\"bindings\": {")
            appendBindings(bindingEntries, into: &lines, indent: 4)
            lines.append("  }")
        }

        lines.append("}")
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
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
        let layout = limited(layout)
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

        // An empty list emits `[]` on purpose. At load, an omitted key
        // means "inherit the action buttons of the game". It brings
        // back buttons that the user deleted.
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
        // Absent and "dpad" mean the same. This keeps every existing
        // file byte stable.
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

    // MARK: - Limits

    private static func limited(_ layout: TouchLayout) -> TouchLayout {
        let maxCount = ControlLimits.maxButtonsPerOrientation
        let buttons = layout.buttons.map { Array($0.prefix(maxCount)) }
        let room = maxCount - (buttons?.count ?? 0)
        let actionButtons = layout.actionButtons.map { Array($0.prefix(room)) }
        return TouchLayout(
            dpad: layout.dpad.map { dpad in
                DPadSpec(
                    x: ControlLimits.coordinate.clamp(dpad.x),
                    y: ControlLimits.coordinate.clamp(dpad.y),
                    size: dpad.size.map(ControlLimits.dpadSize.clamp),
                    opacity: dpad.opacity.map(ControlLimits.opacity.clamp),
                    style: dpad.style)
            },
            buttons: buttons?.map { button in
                let label = button.label.map {
                    String(
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                            .prefix(ControlLimits.maxLabelLength))
                }
                return ButtonSpec(
                    label: label?.isEmpty == false ? label : nil,
                    key: button.key,
                    x: ControlLimits.coordinate.clamp(button.x),
                    y: ControlLimits.coordinate.clamp(button.y),
                    size: button.size.map(ControlLimits.buttonSize.clamp),
                    opacity: button.opacity.map(ControlLimits.opacity.clamp))
            },
            actionButtons: actionButtons?.map { button in
                ActionButtonSpec(
                    action: button.action,
                    x: ControlLimits.coordinate.clamp(button.x),
                    y: ControlLimits.coordinate.clamp(button.y),
                    size: button.size.map(ControlLimits.buttonSize.clamp),
                    opacity: button.opacity.map(ControlLimits.opacity.clamp))
            })
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

import Foundation

/// One touch control per document leaf, per SPEC 10.3.
///
/// Two devices that move different buttons write different leaves,
/// so Automerge merges both moves. The id comes from what the
/// control is, not from where it sits in the file, because a list
/// index moves when a device adds a button.
public enum TouchSectionSyncCoder {

    public static let portraitPrefix = "portrait"
    public static let landscapePrefix = "landscape"

    public static func controls(of section: TouchSection) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        add(section.portrait, prefix: portraitPrefix, into: &out)
        add(section.landscape, prefix: landscapePrefix, into: &out)
        return out
    }

    public static func section(of controls: [String: JSONValue]) -> TouchSection {
        TouchSection(
            portrait: layout(of: controls, prefix: portraitPrefix),
            landscape: layout(of: controls, prefix: landscapePrefix))
    }

    // MARK: - Writing

    private static func add(
        _ layout: TouchLayout?, prefix: String, into out: inout [String: JSONValue]
    ) {
        guard let layout else { return }
        if let dpad = layout.dpad {
            out["\(prefix).dpad"] = value(of: dpad)
        }
        var taken: Set<String> = []
        for button in layout.buttons ?? [] {
            let id = free("\(prefix).key.\(button.key)", taken: &taken)
            out[id] = value(of: button)
        }
        for button in layout.actionButtons ?? [] {
            let id = free("\(prefix).action.\(button.action)", taken: &taken)
            out[id] = value(of: button)
        }
    }

    /// Two buttons may carry the same key in one orientation, so the
    /// second takes a numbered id. The order inside one orientation
    /// is the file's own, which keeps the id stable across a save.
    private static func free(_ id: String, taken: inout Set<String>) -> String {
        var candidate = id
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(id)#\(number)"
            number += 1
        }
        taken.insert(candidate)
        return candidate
    }

    private static func value(of dpad: DPadSpec) -> JSONValue {
        var fields: [String: JSONValue] = ["x": .double(dpad.x), "y": .double(dpad.y)]
        fields["size"] = dpad.size.map(JSONValue.double)
        fields["opacity"] = dpad.opacity.map(JSONValue.double)
        fields["style"] = .string(dpad.style.rawValue)
        return .object(fields.compactMapValues { $0 })
    }

    private static func value(of button: ButtonSpec) -> JSONValue {
        var fields: [String: JSONValue] = [
            "key": .string(button.key), "x": .double(button.x), "y": .double(button.y),
        ]
        fields["label"] = button.label.map(JSONValue.string)
        fields["size"] = button.size.map(JSONValue.double)
        fields["opacity"] = button.opacity.map(JSONValue.double)
        return .object(fields.compactMapValues { $0 })
    }

    private static func value(of button: ActionButtonSpec) -> JSONValue {
        var fields: [String: JSONValue] = [
            "action": .string(button.action), "x": .double(button.x), "y": .double(button.y),
        ]
        fields["size"] = button.size.map(JSONValue.double)
        fields["opacity"] = button.opacity.map(JSONValue.double)
        return .object(fields.compactMapValues { $0 })
    }

    // MARK: - Reading

    private static func layout(of controls: [String: JSONValue], prefix: String) -> TouchLayout? {
        let dpad = controls["\(prefix).dpad"].flatMap(dpadSpec(of:))
        var buttons: [ButtonSpec] = []
        var actionButtons: [ActionButtonSpec] = []
        for id in controls.keys.sorted() {
            guard let value = controls[id] else { continue }
            if id.hasPrefix("\(prefix).key."), let button = buttonSpec(of: value) {
                buttons.append(button)
            }
            if id.hasPrefix("\(prefix).action."), let button = actionButtonSpec(of: value) {
                actionButtons.append(button)
            }
        }
        guard dpad != nil || !buttons.isEmpty || !actionButtons.isEmpty else { return nil }
        return TouchLayout(
            dpad: dpad,
            buttons: buttons.isEmpty ? nil : buttons,
            actionButtons: actionButtons.isEmpty ? nil : actionButtons)
    }

    private static func dpadSpec(of value: JSONValue) -> DPadSpec? {
        guard case .object(let fields) = value,
            let x = number(fields["x"]), let y = number(fields["y"])
        else { return nil }
        return DPadSpec(
            x: x, y: y, size: number(fields["size"]), opacity: number(fields["opacity"]),
            style: fields["style"]?.string.flatMap(MovementStyle.init(rawValue:)) ?? .dpad)
    }

    private static func buttonSpec(of value: JSONValue) -> ButtonSpec? {
        guard case .object(let fields) = value, let key = fields["key"]?.string,
            let x = number(fields["x"]), let y = number(fields["y"])
        else { return nil }
        return ButtonSpec(
            label: fields["label"]?.string, key: key, x: x, y: y,
            size: number(fields["size"]), opacity: number(fields["opacity"]))
    }

    private static func actionButtonSpec(of value: JSONValue) -> ActionButtonSpec? {
        guard case .object(let fields) = value, let action = fields["action"]?.string,
            let x = number(fields["x"]), let y = number(fields["y"])
        else { return nil }
        return ActionButtonSpec(
            action: action, x: x, y: y,
            size: number(fields["size"]), opacity: number(fields["opacity"]))
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: return nil
        }
    }
}

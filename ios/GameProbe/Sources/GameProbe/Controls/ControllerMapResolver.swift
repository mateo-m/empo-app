import Foundation

/// Four-layer controller map merge (SPEC section 9). Builtin is always
/// the base. Each layer in `layers` overlays in order (global, then
/// manifest, then per-game).
public enum ControllerMapResolver {
    public enum ResolvedTarget: Equatable, Sendable {
        case key(Int32)
        case action(String)
        case unbound
    }

    /// SPEC section 9.1 built-in map, as data.
    public static var builtinDefault: ControllerMap {
        ControllerMap(entries: builtinEntries)
    }

    /// Later layers override earlier ones per element. `.unbound` removes.
    public static func resolve(layers: [ControllerMap]) -> [String: ControllerMap.Target] {
        var result = builtinDefault.entries
        for layer in layers {
            for (element, target) in layer.entries {
                switch target {
                case .unbound:
                    result.removeValue(forKey: element)
                case .key, .action:
                    result[element] = target
                }
            }
        }
        return result
    }

    /// Merged map with key codes resolved to scancodes at resolve time.
    public static func resolvedRuntimeMap(layers: [ControllerMap] = []) -> [String: ResolvedTarget] {
        let merged = resolve(layers: layers)
        var out: [String: ResolvedTarget] = [:]
        for (element, target) in merged {
            switch target {
            case .key(let code):
                if let scancode = KeyCodeTable.scancode(for: code) {
                    out[element] = .key(scancode)
                }
            case .action(let name):
                out[element] = .action(name)
            case .unbound:
                break
            }
        }
        return out
    }

    private static let builtinEntries: [String: ControllerMap.Target] = [
        "dpup": .key("ArrowUp"),
        "dpdown": .key("ArrowDown"),
        "dpleft": .key("ArrowLeft"),
        "dpright": .key("ArrowRight"),
        "-leftx": .key("ArrowLeft"),
        "+leftx": .key("ArrowRight"),
        "-lefty": .key("ArrowUp"),
        "+lefty": .key("ArrowDown"),
        "a": .key("Enter"),
        "b": .key("Escape"),
        "x": .key("ShiftLeft"),
        "y": .key("KeyA"),
        "leftshoulder": .key("KeyQ"),
        "rightshoulder": .key("KeyW"),
        "leftstick": .key("KeyS"),
        "rightstick": .key("KeyD"),
        "start": .action("$pauseMenu"),
        "back": .action("$toggleTouchControls"),
    ]
}

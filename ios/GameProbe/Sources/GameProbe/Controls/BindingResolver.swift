import Foundation

/// Four-layer binding merge (SPEC section 9). Builtin is always the
/// base. Each layer in `layers` overlays in order (global, then
/// manifest, then per-game).
///
/// One merged map serves both physical sources. Controller elements
/// resolve straight to their target. Keyboard keys resolve the same
/// way, except that a key bound to an element takes that element's
/// binding, which is how a pad in keyboard mode inherits every bind
/// the same pad would get through the GameController framework.
public enum BindingResolver {
    public enum ResolvedTarget: Equatable, Sendable {
        case key(Int32)
        case action(String)
        case unbound
    }

    /// SPEC section 9.1 built-in map, as data.
    public static var builtinDefault: BindingMap {
        BindingMap(entries: builtinEntries)
    }

    /// Later layers override earlier ones per source. `.unbound`
    /// removes an element binding, because an unbound element has
    /// nothing left to do. A key keeps its `.unbound` entry: dropping
    /// it would fall back to pass-through and the key would type
    /// again.
    public static func resolve(layers: [BindingMap]) -> [String: BindingMap.Target] {
        var result = builtinDefault.entries
        for layer in layers {
            for (source, target) in layer.entries {
                if case .unbound = target, ControllerElement.allNames.contains(source) {
                    result.removeValue(forKey: source)
                } else {
                    result[source] = target
                }
            }
        }
        return result
    }

    /// Merged element bindings with key codes resolved to scancodes.
    public static func resolvedRuntimeMap(layers: [BindingMap] = []) -> [String: ResolvedTarget] {
        let merged = resolve(layers: layers)
        var out: [String: ResolvedTarget] = [:]
        for (source, target) in merged where ControllerElement.allNames.contains(source) {
            switch target {
            case .key(let code):
                if let scancode = KeyCodeTable.scancode(for: code) {
                    out[source] = .key(scancode)
                }
            case .action(let name):
                out[source] = .action(name)
            case .element, .unbound:
                // Element chains are rejected at parse time (V023) and
                // unbound elements never reach this map.
                break
            }
        }
        return out
    }

    /// Merged key bindings, keyed by the scancode of the physical key.
    /// A key that is absent from this map passes through to the game
    /// unchanged, so a plain keyboard keeps typing.
    public static func resolvedKeyMap(layers: [BindingMap] = []) -> [Int32: ResolvedTarget] {
        let merged = resolve(layers: layers)
        let elements = resolvedRuntimeMap(layers: layers)
        var out: [Int32: ResolvedTarget] = [:]
        for (source, target) in merged where !ControllerElement.allNames.contains(source) {
            guard let from = KeyCodeTable.scancode(for: source) else { continue }
            switch target {
            case .key(let code):
                if let scancode = KeyCodeTable.scancode(for: code) {
                    out[from] = .key(scancode)
                }
            case .element(let name):
                // The element's own binding decides what the key does.
                // An element with no binding leaves the key silent:
                // the player asked for a pad button, not for the key.
                out[from] = elements[name] ?? .unbound
            case .action(let name):
                out[from] = .action(name)
            case .unbound:
                out[from] = .unbound
            }
        }
        return out
    }

    private static let builtinEntries: [String: BindingMap.Target] = [
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

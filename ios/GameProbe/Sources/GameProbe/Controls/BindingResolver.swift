import Foundation

/// What a physical input does once every layer has had its say.
public enum ResolvedTarget: Equatable, Sendable {
    case key(Int32)
    case action(String)
    case unbound
}

/// The merged map both input paths read: elements by name, keys by
/// the scancode of the physical key.
///
/// A key absent from `keys` passes through to the game unchanged, so
/// a real keyboard keeps typing.
public struct ResolvedBindings: Equatable, Sendable {
    public var elements: [String: ResolvedTarget]
    public var keys: [Int32: ResolvedTarget]

    public init(
        elements: [String: ResolvedTarget] = [:],
        keys: [Int32: ResolvedTarget] = [:]
    ) {
        self.elements = elements
        self.keys = keys
    }
}

/// Four-layer binding merge (SPEC section 9). Builtin is always the
/// base. Each layer in `layers` overlays in order (global, then
/// manifest, then per-game).
///
/// A key bound to an element takes that element's binding, which is
/// how a pad in keyboard mode inherits every bind the same pad would
/// get through the GameController framework.
public enum BindingResolver {
    /// SPEC section 9.1 built-in map, as data.
    public static var builtinDefault: BindingMap {
        BindingMap(entries: builtinEntries)
    }

    /// Later layers override earlier ones per source. `.unbound`
    /// removes an element binding, because an unbound element has
    /// nothing left to do. A key keeps its `.unbound` entry: dropping
    /// it would fall back to pass-through and the key would type
    /// again.
    public static func resolve(layers: [BindingMap]) -> [BindingSource: ControlsTarget] {
        var result = builtinEntries
        for layer in layers {
            for (source, target) in layer.entries {
                if target == .unbound, source.isElement {
                    result.removeValue(forKey: source)
                } else {
                    result[source] = target
                }
            }
        }
        return result
    }

    /// Both runtime maps from one merge.
    public static func resolveRuntime(layers: [BindingMap] = []) -> ResolvedBindings {
        let merged = BindingMap(entries: resolve(layers: layers))

        var elements: [String: ResolvedTarget] = [:]
        for (name, target) in merged.elementEntries {
            // Element chains are rejected at parse time, and unbound
            // elements never survive the merge.
            if let resolved = runtimeTarget(target) {
                elements[name] = resolved
            }
        }

        var keys: [Int32: ResolvedTarget] = [:]
        for (name, target) in merged.keyEntries {
            guard let scancode = KeyCodeTable.scancode(for: name) else { continue }
            if case .element(let element) = target {
                // The element's own binding decides what the key does.
                // An element with no binding leaves the key silent:
                // the player asked for a pad button, not for the key.
                keys[scancode] = elements[element] ?? .unbound
                continue
            }
            keys[scancode] = runtimeTarget(target) ?? .unbound
        }

        return ResolvedBindings(elements: elements, keys: keys)
    }

    private static func runtimeTarget(_ target: ControlsTarget) -> ResolvedTarget? {
        switch target {
        case .key(let code):
            return KeyCodeTable.scancode(for: code).map(ResolvedTarget.key)
        case .action(let id):
            return .action(id)
        case .unbound:
            return .unbound
        case .element:
            return nil
        }
    }

    private static let builtinEntries: [BindingSource: ControlsTarget] = [
        .element("dpup"): .key("ArrowUp"),
        .element("dpdown"): .key("ArrowDown"),
        .element("dpleft"): .key("ArrowLeft"),
        .element("dpright"): .key("ArrowRight"),
        .element("-leftx"): .key("ArrowLeft"),
        .element("+leftx"): .key("ArrowRight"),
        .element("-lefty"): .key("ArrowUp"),
        .element("+lefty"): .key("ArrowDown"),
        .element("a"): .key("Enter"),
        .element("b"): .key("Escape"),
        .element("x"): .key("ShiftLeft"),
        .element("y"): .key("KeyA"),
        .element("leftshoulder"): .key("KeyQ"),
        .element("rightshoulder"): .key("KeyW"),
        .element("leftstick"): .key("KeyS"),
        .element("rightstick"): .key("KeyD"),
        .element("start"): .action("$pauseMenu"),
        .element("back"): .action("$toggleTouchControls"),
    ]
}

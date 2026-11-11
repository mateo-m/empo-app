// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum ResolvedTarget: Equatable, Sendable {
    case key(Int32)
    case action(String)
    case unbound
}

/// A key that is not in `keys` goes to the game unchanged, so that a
/// real keyboard keeps typing and the engine hotkeys keep working.
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

/// Callers give `layers` in this order: global, then manifest, then
/// per-game.
public enum BindingResolver {
    public static var builtinDefault: BindingMap {
        BindingMap(entries: builtinEntries)
    }

    /// A key keeps its `.unbound` entry. Without it, the key falls back
    /// to pass-through and types again.
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

    public static func resolveRuntime(layers: [BindingMap] = []) -> ResolvedBindings {
        let merged = BindingMap(entries: resolve(layers: layers))

        var elements: [String: ResolvedTarget] = [:]
        for (name, target) in merged.elementEntries {
            // The parser rejects element chains, and the merge removes
            // unbound elements.
            if let resolved = runtimeTarget(target) {
                elements[name] = resolved
            }
        }

        var keys: [Int32: ResolvedTarget] = [:]
        for (name, target) in merged.keyEntries {
            guard let scancode = KeyCodeTable.scancode(for: name) else { continue }
            if case .element(let element) = target {
                // An element with no binding makes the key silent. The
                // player asked for a pad button, not for the key.
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
        .element("start"): .action(EmpoActionCatalog.pauseMenu),
        .element("back"): .action(EmpoActionCatalog.toggleTouchControls),
    ]
}

import Foundation
import GameProbe

/// Table-driven controller element labels and remap UI metadata (ticket 005).
@MainActor
enum ControllerRemapCatalog {

    enum Scope: String, CaseIterable {
        case thisGame = "This game"
        case allGames = "All games"
    }

    enum Provenance {
        case userOverride
        case gameDefault
        case empoDefault
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let elements: [Element]
    }

    struct Element: Identifiable, Hashable {
        let id: String
        let label: String
    }

    /// RPG Maker meaning hints for the Common key group (ticket 005 §4).
    static let commonKeyAnnotations: [String: String] = [
        "Enter": "Confirm",
        "Space": "Confirm",
        "Escape": "Cancel / menu",
        "KeyX": "Cancel / menu",
        "ShiftLeft": "Dash",
        "KeyZ": "Confirm (VX/Ace)",
        "KeyQ": "Page up (L)",
        "KeyW": "Page down (R)",
        "KeyA": "X key",
        "KeyS": "Y key",
        "KeyD": "Z key",
        "F5": "Script hotkeys",
        "F6": "Script hotkeys",
        "F7": "Script hotkeys",
        "F8": "Script hotkeys",
        "F9": "Script hotkeys",
    ]

    private static let baseSections: [Section] = [
        Section(
            id: "face",
            title: "Face buttons",
            elements: [
                Element(id: "a", label: "A / Cross (south)"),
                Element(id: "b", label: "B / Circle (east)"),
                Element(id: "x", label: "X / Square (west)"),
                Element(id: "y", label: "Y / Triangle (north)"),
            ]),
        Section(
            id: "dpad",
            title: "D-pad",
            elements: [
                Element(id: "dpup", label: "D-pad up"),
                Element(id: "dpdown", label: "D-pad down"),
                Element(id: "dpleft", label: "D-pad left"),
                Element(id: "dpright", label: "D-pad right"),
            ]),
        Section(
            id: "leftStick",
            title: "Left stick",
            elements: [
                Element(id: "-leftx", label: "Left stick ←"),
                Element(id: "+leftx", label: "Left stick →"),
                Element(id: "-lefty", label: "Left stick ↑"),
                Element(id: "+lefty", label: "Left stick ↓"),
                Element(id: "leftstick", label: "L3 click"),
            ]),
        Section(
            id: "rightStick",
            title: "Right stick",
            elements: [
                Element(id: "-rightx", label: "Right stick ←"),
                Element(id: "+rightx", label: "Right stick →"),
                Element(id: "-righty", label: "Right stick ↑"),
                Element(id: "+righty", label: "Right stick ↓"),
                Element(id: "rightstick", label: "R3 click"),
            ]),
        Section(
            id: "shoulders",
            title: "Shoulders & triggers",
            elements: [
                Element(id: "leftshoulder", label: "LB / L1"),
                Element(id: "rightshoulder", label: "RB / R1"),
                Element(id: "lefttrigger", label: "LT / L2"),
                Element(id: "righttrigger", label: "RT / R2"),
            ]),
        Section(
            id: "system",
            title: "System",
            elements: [
                Element(id: "start", label: "Menu / Start"),
                Element(id: "back", label: "Options / Select"),
                Element(id: "guide", label: "Home / Guide (often reserved by iOS)"),
            ]),
    ]

    private static let extrasSection = Section(
        id: "extras",
        title: "Extras",
        elements: [
            Element(id: "paddle1", label: "Paddle 1"),
            Element(id: "paddle2", label: "Paddle 2"),
            Element(id: "paddle3", label: "Paddle 3"),
            Element(id: "paddle4", label: "Paddle 4"),
            Element(id: "touchpad", label: "Touchpad click"),
        ])

    static func sections(includingOptional exposed: Set<String>) -> [Section] {
        var result = baseSections
        let extras = extrasSection.elements.filter { exposed.contains($0.id) }
        if !extras.isEmpty {
            result.append(Section(id: "extras", title: "Extras", elements: extras))
        }
        return result
    }

    /// Label for one physical key, for the keyboard rows.
    static func keyLabel(_ code: String) -> String {
        let name = KeyCodeTable.displayName(for: code) ?? code
        return name == code ? name : "\(name) (\(code))"
    }

    /// Label for a controller element, for element targets and rows.
    static func elementLabel(_ element: String) -> String {
        for section in baseSections + [extrasSection] {
            if let match = section.elements.first(where: { $0.id == element }) {
                return match.label
            }
        }
        return element
    }

    /// Key sources bound in this scope, in key-table order. These are
    /// the rows of the keyboard section: a controller in keyboard
    /// mode has no elements to list, only the keys it sends.
    static func keySources(
        scope: Scope,
        container: GameContainer?,
        manifest: BindingMap?
    ) -> [Element] {
        let layers: [BindingMap]
        switch scope {
        case .thisGame:
            layers = BindingLayers.overrideLayers(for: container)
        case .allGames:
            layers = [BindingStore.loadGlobal()].compactMap { $0 }
        }
        let merged = BindingResolver.resolve(layers: layers)
        let bound = Set(merged.keys).subtracting(ControllerElement.allNames)
        return KeyCodeTable.allCodes
            .filter { bound.contains($0) }
            .map { Element(id: $0, label: keyLabel($0)) }
    }

    static func displayName(for target: BindingMap.Target?) -> String {
        guard let target else { return "Unbound" }
        switch target {
        case .key(let code):
            return KeyCodeTable.displayName(for: code) ?? code
        case .element(let name):
            return elementLabel(name)
        case .action(let name):
            // Unknown = written by a newer Empo or by hand. The
            // binding stays in the map (W005 rule) and does nothing.
            return EmpoActionCatalog.action(id: name)?.displayName
                ?? "Unavailable action (\(name))"
        case .unbound:
            return "Unbound"
        }
    }

    static func provenance(
        element: String,
        scope: Scope,
        container: GameContainer?,
        manifest: BindingMap?
    ) -> Provenance? {
        switch scope {
        case .thisGame:
            if let container,
                let perGame = BindingStore.loadPerGame(container: container),
                perGame.entries[element] != nil
            {
                return .userOverride
            }
            if let manifest, manifest.entries[element] != nil {
                return .gameDefault
            }
            if let global = BindingStore.loadGlobal(),
                global.entries[element] != nil
            {
                return nil
            }
            return .empoDefault
        case .allGames:
            if let global = BindingStore.loadGlobal(),
                global.entries[element] != nil
            {
                return .userOverride
            }
            return .empoDefault
        }
    }

    static func resolvedTarget(
        element: String,
        scope: Scope,
        container: GameContainer?,
        manifest: BindingMap?
    ) -> BindingMap.Target? {
        let layers: [BindingMap]
        switch scope {
        case .thisGame:
            layers = BindingLayers.overrideLayers(for: container)
        case .allGames:
            layers = [BindingStore.loadGlobal()].compactMap { $0 }
        }
        let merged = BindingResolver.resolve(layers: layers)
        return merged[element]
    }

    static func save(
        element: String,
        target: BindingMap.Target,
        scope: Scope,
        container: GameContainer?
    ) {
        switch scope {
        case .thisGame:
            guard let container else { return }
            var map = BindingStore.loadPerGame(container: container) ?? BindingMap()
            map.entries[element] = target
            BindingStore.savePerGame(container: container, map: map)
        case .allGames:
            var map = BindingStore.loadGlobal() ?? BindingMap()
            map.entries[element] = target
            BindingStore.saveGlobal(map)
        }
    }

    static func removeOverride(
        element: String,
        scope: Scope,
        container: GameContainer?
    ) {
        switch scope {
        case .thisGame:
            guard let container,
                var map = BindingStore.loadPerGame(container: container)
            else { return }
            map.entries.removeValue(forKey: element)
            if map.entries.isEmpty {
                BindingStore.deletePerGame(container: container)
            } else {
                BindingStore.savePerGame(container: container, map: map)
            }
        case .allGames:
            guard var map = BindingStore.loadGlobal() else { return }
            map.entries.removeValue(forKey: element)
            if map.entries.isEmpty {
                BindingStore.deleteGlobal()
            } else {
                BindingStore.saveGlobal(map)
            }
        }
    }

    static func resetOverrides(scope: Scope, container: GameContainer?) {
        switch scope {
        case .thisGame:
            guard let container else { return }
            BindingStore.deletePerGame(container: container)
        case .allGames:
            BindingStore.deleteGlobal()
        }
    }

    static func hasOverrides(scope: Scope, container: GameContainer?) -> Bool {
        switch scope {
        case .thisGame:
            guard let container else { return false }
            return BindingStore.loadPerGame(container: container) != nil
        case .allGames:
            return BindingStore.loadGlobal() != nil
        }
    }
}

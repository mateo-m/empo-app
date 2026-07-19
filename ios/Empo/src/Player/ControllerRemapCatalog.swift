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

    static func displayName(for target: ControllerMap.Target?) -> String {
        guard let target else { return "Unbound" }
        switch target {
        case .key(let code):
            return KeyCodeTable.displayName(for: code) ?? code
        case .action(let name):
            switch name {
            case "$pauseMenu": return "Pause menu"
            case "$toggleOverlay": return "Toggle overlay"
            default: return name
            }
        case .unbound:
            return "Unbound"
        }
    }

    static func provenance(
        element: String,
        scope: Scope,
        gameID: String?,
        manifest: ControllerMap?
    ) -> Provenance? {
        switch scope {
        case .thisGame:
            if let perGame = ControllerMapStore.loadPerGame(gameID: gameID ?? ""),
                perGame.entries[element] != nil
            {
                return .userOverride
            }
            if let manifest, manifest.entries[element] != nil {
                return .gameDefault
            }
            if let global = ControllerMapStore.loadGlobal(),
                global.entries[element] != nil
            {
                return nil
            }
            return .empoDefault
        case .allGames:
            if let global = ControllerMapStore.loadGlobal(),
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
        gameID: String?,
        manifest: ControllerMap?
    ) -> ControllerMap.Target? {
        let layers: [ControllerMap]
        switch scope {
        case .thisGame:
            layers = ControllerMapBindings.overrideLayers(for: gameID)
        case .allGames:
            layers = [ControllerMapStore.loadGlobal()].compactMap { $0 }
        }
        let merged = ControllerMapResolver.resolve(layers: layers)
        return merged[element]
    }

    static func save(
        element: String,
        target: ControllerMap.Target,
        scope: Scope,
        gameID: String?
    ) {
        switch scope {
        case .thisGame:
            guard let gameID else { return }
            var map = ControllerMapStore.loadPerGame(gameID: gameID) ?? ControllerMap()
            map.entries[element] = target
            ControllerMapStore.savePerGame(gameID: gameID, map: map)
        case .allGames:
            var map = ControllerMapStore.loadGlobal() ?? ControllerMap()
            map.entries[element] = target
            ControllerMapStore.saveGlobal(map)
        }
    }

    static func removeOverride(
        element: String,
        scope: Scope,
        gameID: String?
    ) {
        switch scope {
        case .thisGame:
            guard let gameID,
                var map = ControllerMapStore.loadPerGame(gameID: gameID)
            else { return }
            map.entries.removeValue(forKey: element)
            if map.entries.isEmpty {
                ControllerMapStore.deletePerGame(gameID: gameID)
            } else {
                ControllerMapStore.savePerGame(gameID: gameID, map: map)
            }
        case .allGames:
            guard var map = ControllerMapStore.loadGlobal() else { return }
            map.entries.removeValue(forKey: element)
            if map.entries.isEmpty {
                ControllerMapStore.deleteGlobal()
            } else {
                ControllerMapStore.saveGlobal(map)
            }
        }
    }

    static func resetOverrides(scope: Scope, gameID: String?) {
        switch scope {
        case .thisGame:
            guard let gameID else { return }
            ControllerMapStore.deletePerGame(gameID: gameID)
        case .allGames:
            ControllerMapStore.deleteGlobal()
        }
    }

    static func hasOverrides(scope: Scope, gameID: String?) -> Bool {
        switch scope {
        case .thisGame:
            guard let gameID else { return false }
            return ControllerMapStore.loadPerGame(gameID: gameID) != nil
        case .allGames:
            return ControllerMapStore.loadGlobal() != nil
        }
    }
}

import Foundation
import GameProbe

/// Table-driven labels and scope handling for the bindings screen
/// (ticket 005). Everything here speaks `BindingSource`, so a row is
/// a row whether it reads a pad element or a key.
@MainActor
enum BindingsCatalog {

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
        let elements: [Row]
    }

    struct Row: Identifiable, Hashable {
        let source: BindingSource
        let label: String

        var id: String { source.name }
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
                Row(source: .element("a"), label: "A / Cross (south)"),
                Row(source: .element("b"), label: "B / Circle (east)"),
                Row(source: .element("x"), label: "X / Square (west)"),
                Row(source: .element("y"), label: "Y / Triangle (north)"),
            ]),
        Section(
            id: "dpad",
            title: "D-pad",
            elements: [
                Row(source: .element("dpup"), label: "D-pad up"),
                Row(source: .element("dpdown"), label: "D-pad down"),
                Row(source: .element("dpleft"), label: "D-pad left"),
                Row(source: .element("dpright"), label: "D-pad right"),
            ]),
        Section(
            id: "leftStick",
            title: "Left stick",
            elements: [
                Row(source: .element("-leftx"), label: "Left stick ←"),
                Row(source: .element("+leftx"), label: "Left stick →"),
                Row(source: .element("-lefty"), label: "Left stick ↑"),
                Row(source: .element("+lefty"), label: "Left stick ↓"),
                Row(source: .element("leftstick"), label: "L3 click"),
            ]),
        Section(
            id: "rightStick",
            title: "Right stick",
            elements: [
                Row(source: .element("-rightx"), label: "Right stick ←"),
                Row(source: .element("+rightx"), label: "Right stick →"),
                Row(source: .element("-righty"), label: "Right stick ↑"),
                Row(source: .element("+righty"), label: "Right stick ↓"),
                Row(source: .element("rightstick"), label: "R3 click"),
            ]),
        Section(
            id: "shoulders",
            title: "Shoulders & triggers",
            elements: [
                Row(source: .element("leftshoulder"), label: "LB / L1"),
                Row(source: .element("rightshoulder"), label: "RB / R1"),
                Row(source: .element("lefttrigger"), label: "LT / L2"),
                Row(source: .element("righttrigger"), label: "RT / R2"),
            ]),
        Section(
            id: "system",
            title: "System",
            elements: [
                Row(source: .element("start"), label: "Menu / Start"),
                Row(source: .element("back"), label: "Options / Select"),
                Row(source: .element("guide"), label: "Home / Guide (often reserved by iOS)"),
            ]),
    ]

    private static let extrasSection = Section(
        id: "extras",
        title: "Extras",
        elements: [
            Row(source: .element("paddle1"), label: "Paddle 1"),
            Row(source: .element("paddle2"), label: "Paddle 2"),
            Row(source: .element("paddle3"), label: "Paddle 3"),
            Row(source: .element("paddle4"), label: "Paddle 4"),
            Row(source: .element("touchpad"), label: "Touchpad click"),
        ])

    static func sections(includingOptional exposed: Set<String>) -> [Section] {
        var result = baseSections
        let extras = extrasSection.elements.filter { exposed.contains($0.source.name) }
        if !extras.isEmpty {
            result.append(Section(id: "extras", title: "Extras", elements: extras))
        }
        return result
    }

    /// Row label for any source.
    static func label(for source: BindingSource) -> String {
        switch source {
        case .element(let name):
            for section in baseSections + [extrasSection] {
                if let match = section.elements.first(where: { $0.source == source }) {
                    return match.label
                }
            }
            return name
        case .key(let code):
            let name = KeyCodeTable.displayName(for: code) ?? code
            return name == code ? name : "\(name) (\(code))"
        }
    }

    /// Rows for the keyboard section: the keys bound in this scope,
    /// in key-table order. A controller in keyboard mode has no
    /// elements to list, only the keys it sends.
    static func keyRows(scope: Scope, container: GameContainer?) -> [Row] {
        let bound = Set(mergedMap(scope: scope, container: container).keys.map(\.name))
        return KeyCodeTable.allCodes
            .filter { bound.contains($0) }
            .map { Row(source: .key($0), label: label(for: .key($0))) }
    }

    private static func mergedMap(
        scope: Scope,
        container: GameContainer?
    ) -> [BindingSource: ControlsTarget] {
        switch scope {
        case .thisGame:
            return BindingResolver.resolve(layers: BindingLayers.overrideLayers(for: container))
        case .allGames:
            return BindingResolver.resolve(layers: [BindingStore.loadGlobal()].compactMap { $0 })
        }
    }

    static func displayName(for target: BindingMap.Target?) -> String {
        guard let target else { return "Unbound" }
        switch target {
        case .key(let code):
            return KeyCodeTable.displayName(for: code) ?? code
        case .element(let name):
            return label(for: .element(name))
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
        source: BindingSource,
        scope: Scope,
        container: GameContainer?,
        manifest: BindingMap?
    ) -> Provenance? {
        switch scope {
        case .thisGame:
            if let container,
                let perGame = BindingStore.loadPerGame(container: container),
                perGame.entries[source] != nil
            {
                return .userOverride
            }
            if let manifest, manifest.entries[source] != nil {
                return .gameDefault
            }
            if let global = BindingStore.loadGlobal(), global.entries[source] != nil {
                return nil
            }
            return .empoDefault
        case .allGames:
            if let global = BindingStore.loadGlobal(), global.entries[source] != nil {
                return .userOverride
            }
            return .empoDefault
        }
    }

    static func resolvedTarget(
        source: BindingSource,
        scope: Scope,
        container: GameContainer?,
        manifest: BindingMap?
    ) -> BindingMap.Target? {
        mergedMap(scope: scope, container: container)[source]
    }

    static func save(
        source: BindingSource,
        target: BindingMap.Target,
        scope: Scope,
        container: GameContainer?
    ) {
        edit(scope: scope, container: container) { $0.entries[source] = target }
    }

    static func removeOverride(
        source: BindingSource,
        scope: Scope,
        container: GameContainer?
    ) {
        edit(scope: scope, container: container) { $0.entries.removeValue(forKey: source) }
    }

    /// Load, change, save. An edit that empties the map removes the
    /// stored override instead of leaving an empty one behind.
    private static func edit(
        scope: Scope,
        container: GameContainer?,
        _ change: (inout BindingMap) -> Void
    ) {
        switch scope {
        case .thisGame:
            guard let container else { return }
            var map = BindingStore.loadPerGame(container: container) ?? BindingMap()
            change(&map)
            if map.entries.isEmpty {
                BindingStore.deletePerGame(container: container)
            } else {
                BindingStore.savePerGame(container: container, map: map)
            }
        case .allGames:
            var map = BindingStore.loadGlobal() ?? BindingMap()
            change(&map)
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

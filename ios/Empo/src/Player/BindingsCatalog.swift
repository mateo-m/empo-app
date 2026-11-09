// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

/// Table-driven labels and scope handling for the bindings screen
/// (ticket 005). Everything here speaks `BindingSource`, so a row is
/// a row whether it reads a pad element or a key.
@MainActor
enum BindingsCatalog {

    enum Scope: CaseIterable {
        case thisGame
        case allGames

        var title: LocalizedStringResource {
            switch self {
            case .thisGame: "This game"
            case .allGames: "All games"
            }
        }
    }

    enum Provenance {
        case userOverride
        case gameDefault
        case empoDefault

        var label: LocalizedStringResource? {
            switch self {
            case .gameDefault: "Game default"
            case .empoDefault: "Empo default"
            case .userOverride: nil
            }
        }
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

    /// What each key of the common group does in most RPG Maker games.
    static let commonKeyAnnotations: [String: String] = [
        "Enter": String(
            localized: "Confirm",
            comment: "What this key does in most RPG Maker games. Shown next to the key name in the key list."
        ),
        "Space": String(localized: "Confirm"),
        "Escape": String(
            localized: "Cancel / menu",
            comment: "What this key does in most RPG Maker games. Shown next to the key name in the key list."
        ),
        "KeyX": String(localized: "Cancel / menu"),
        "ShiftLeft": String(
            localized: "Dash",
            comment: "What this key does in most RPG Maker games. Shown next to the key name in the key list."
        ),
        "KeyZ": String(localized: "Confirm (VX/Ace)"),
        "KeyQ": String(localized: "Page up (L)"),
        "KeyW": String(localized: "Page down (R)"),
        "KeyA": String(localized: "RPG Maker X button"),
        "KeyS": String(localized: "RPG Maker Y button"),
        "KeyD": String(localized: "RPG Maker Z button"),
        "F5": String(localized: "Script hotkeys"),
        "F6": String(localized: "Script hotkeys"),
        "F7": String(localized: "Script hotkeys"),
        "F8": String(localized: "Script hotkeys"),
        "F9": String(localized: "Script hotkeys"),
    ]

    private static let baseSections: [Section] = [
        Section(
            id: "face",
            title: String(localized: "Face buttons"),
            elements: [
                Row(
                    source: .element("a"),
                    label: String(localized: "A / Cross (south)")),
                Row(
                    source: .element("b"),
                    label: String(localized: "B / Circle (east)")),
                Row(
                    source: .element("x"),
                    label: String(localized: "X / Square (west)")),
                Row(
                    source: .element("y"),
                    label: String(localized: "Y / Triangle (north)")),
            ]),
        Section(
            id: "dpad",
            title: String(localized: "D-pad"),
            elements: [
                Row(
                    source: .element("dpup"),
                    label: String(localized: "D-pad up")),
                Row(
                    source: .element("dpdown"),
                    label: String(localized: "D-pad down")),
                Row(
                    source: .element("dpleft"),
                    label: String(localized: "D-pad left")),
                Row(
                    source: .element("dpright"),
                    label: String(localized: "D-pad right")),
            ]),
        Section(
            id: "leftStick",
            title: String(localized: "Left stick"),
            elements: [
                Row(
                    source: .element("-leftx"),
                    label: String(localized: "Left stick left")),
                Row(
                    source: .element("+leftx"),
                    label: String(localized: "Left stick right")),
                Row(
                    source: .element("-lefty"),
                    label: String(localized: "Left stick up")),
                Row(
                    source: .element("+lefty"),
                    label: String(localized: "Left stick down")),
                Row(
                    source: .element("leftstick"),
                    label: String(localized: "L3 click")),
            ]),
        Section(
            id: "rightStick",
            title: String(localized: "Right stick"),
            elements: [
                Row(
                    source: .element("-rightx"),
                    label: String(localized: "Right stick left")),
                Row(
                    source: .element("+rightx"),
                    label: String(localized: "Right stick right")),
                Row(
                    source: .element("-righty"),
                    label: String(localized: "Right stick up")),
                Row(
                    source: .element("+righty"),
                    label: String(localized: "Right stick down")),
                Row(
                    source: .element("rightstick"),
                    label: String(localized: "R3 click")),
            ]),
        Section(
            id: "shoulders",
            title: String(localized: "Shoulders & triggers"),
            elements: [
                Row(source: .element("leftshoulder"), label: "LB / L1"),
                Row(source: .element("rightshoulder"), label: "RB / R1"),
                Row(source: .element("lefttrigger"), label: "LT / L2"),
                Row(source: .element("righttrigger"), label: "RT / R2"),
            ]),
        Section(
            id: "system",
            title: String(
                localized: "System buttons",
                comment: "Section of controller buttons: Menu, Options, and Home."),
            elements: [
                Row(
                    source: .element("start"),
                    label: String(localized: "Menu / Start")),
                Row(
                    source: .element("back"),
                    label: String(localized: "Options / Select")),
                Row(
                    source: .element("guide"),
                    label: {
                        #if os(macOS)
                        String(localized: "Home / Guide")
                        #else
                        String(localized: "Home / Guide (iOS often uses this)")
                        #endif
                    }()),
            ]),
    ]

    private static let extrasSection = Section(
        id: "extras",
        title: String(localized: "Extras"),
        elements: [
            Row(
                source: .element("paddle1"),
                label: String(
                    localized: "Paddle 1", comment: "A game controller button, in the controller button list."
                )),
            Row(
                source: .element("paddle2"),
                label: String(
                    localized: "Paddle 2", comment: "A game controller button, in the controller button list."
                )),
            Row(
                source: .element("paddle3"),
                label: String(
                    localized: "Paddle 3", comment: "A game controller button, in the controller button list."
                )),
            Row(
                source: .element("paddle4"),
                label: String(
                    localized: "Paddle 4", comment: "A game controller button, in the controller button list."
                )),
            Row(
                source: .element("touchpad"),
                label: String(localized: "Touchpad click")),
        ])

    static let optionalElements = Set(extrasSection.elements.map(\.source.name))

    static func sections(includingOptional exposed: Set<String>) -> [Section] {
        var result = baseSections
        let extras = extrasSection.elements.filter { exposed.contains($0.source.name) }
        if !extras.isEmpty {
            result.append(
                Section(
                    id: "extras",
                    title: String(localized: "Extras"),
                    elements: extras))
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
            return name == code
                ? name
                : String(
                    localized: "\(name) (\(code))",
                    comment: "A keyboard key: its name, then its key code in parentheses."
                )
        }
    }

    /// The bindings of one scope, read from disk once for a screen update.
    @MainActor
    struct SavedBindings {
        private let scope: Scope
        private let manifest: BindingMap?
        private let global: BindingMap?
        private let perGame: BindingMap?
        private let merged: [BindingSource: ControlsTarget]

        init(scope: Scope, container: GameContainer?, manifest: BindingMap?) {
            self.scope = scope
            self.manifest = manifest
            let global = BindingStore.loadGlobal()
            self.global = global
            switch scope {
            case .thisGame:
                let perGame = container.flatMap(BindingStore.loadPerGame)
                self.perGame = perGame
                merged = BindingResolver.resolve(
                    layers: BindingLayers.overrideLayers(global: global, manifest: manifest, perGame: perGame)
                )
            case .allGames:
                perGame = nil
                merged = BindingResolver.resolve(layers: [global].compactMap { $0 })
            }
        }

        var hasOverrides: Bool {
            (scope == .thisGame ? perGame : global) != nil
        }

        /// Rows for the keyboard section: the keys bound in this scope,
        /// in key-table order. A controller in keyboard mode has no
        /// elements to list, only the keys it sends.
        var keyRows: [Row] {
            let bound = Set(merged.keys.map(\.name))
            return KeyCodeTable.allCodes
                .filter { bound.contains($0) }
                .map { Row(source: .key($0), label: BindingsCatalog.label(for: .key($0))) }
        }

        func target(for source: BindingSource) -> BindingMap.Target? {
            switch merged[source] {
            case nil where source.isElement:
                // The merge drops an unbound element.
                return .unbound
            case .action(let id)?
            where EmpoActionCatalog.action(id: id) != nil && !PlayerActionRegistry.actionIDs.contains(id):
                return .unbound
            case let target:
                return target
            }
        }

        func provenance(for source: BindingSource) -> Provenance? {
            switch scope {
            case .thisGame:
                if perGame?.entries[source] != nil { return .userOverride }
                if manifest?.entries[source] != nil { return .gameDefault }
                if global?.entries[source] != nil { return nil }
                return .empoDefault
            case .allGames:
                return global?.entries[source] != nil ? .userOverride : .empoDefault
            }
        }
    }

    static func displayName(for target: BindingMap.Target?) -> String {
        guard let target else {
            return String(localized: "None", comment: "A controller button that does nothing.")
        }
        switch target {
        case .key(let code):
            return KeyCodeTable.displayName(for: code) ?? code
        case .element(let name):
            return label(for: .element(name))
        case .action(let name):
            // Unknown = written by a newer Empo or by hand. The
            // binding stays in the map (W005 rule) and does nothing.
            return EmpoActionCatalog.action(id: name)?.localizedName
                ?? String(localized: "Not supported in this version of Empo")
        case .unbound:
            return String(localized: "None", comment: "A controller button that does nothing.")
        }
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

    static func resetTitle(scope: Scope) -> LocalizedStringResource {
        scope == .thisGame ? "Reset buttons for this game?" : "Reset buttons for all games?"
    }

    static func resetFooter(scope: Scope) -> LocalizedStringResource {
        switch scope {
        case .thisGame:
            return "Clears the buttons you changed for this game."
        case .allGames:
            return "Clears the buttons you changed for all games. Buttons you changed for one game stay."
        }
    }

    /// A button can get an action that this game cannot run when the
    /// binding is for all games, because other games can run it.
    static func offersAction(available: Bool, scope: Scope) -> Bool {
        available || scope == .allGames
    }

    enum UnavailableNotePlace {
        case editModeBadge
        case addButtonSheet
        case bindingList(Scope)
    }

    static func unavailableActionNote(_ actionID: String, in place: UnavailableNotePlace) -> String {
        let cheats = actionID == EmpoActionCatalog.toggleCheats
        switch place {
        case .editModeBadge:
            return cheats
                ? String(localized: "This game has no cheats.")
                : String(localized: "Turn this on in this game's settings")
        case .addButtonSheet:
            return cheats
                ? String(localized: "This game has no cheats. The button shows in games that have cheats.")
                : String(
                    localized:
                        "Fast forward is off for this game. The button shows in games that have Fast forward on."
                )
        case .bindingList(.thisGame):
            return cheats
                ? String(localized: "This game has no cheats.")
                : String(localized: "Fast forward is off for this game. Turn it on in this game's settings.")
        case .bindingList(.allGames):
            return cheats
                ? String(localized: "This game has no cheats. This button works in games that have cheats.")
                : String(
                    localized:
                        "Fast forward is off for this game. This button works in games that have Fast forward on."
                )
        }
    }

    struct TargetChoice: Identifiable {
        let title: String
        var blurb: String?
        var note: String?
        let target: BindingMap.Target
        var enabled = true

        var id: String { "\(target)" }
    }

    struct TargetChoiceGroup: Identifiable {
        let title: String
        let choices: [TargetChoice]

        var id: String { title }
    }

    /// What a binding row can do, in the order that the picker shows it:
    /// the actions with "Do nothing", the controller buttons when the
    /// source is a key, then one group for each kind of key.
    static func targetChoices(
        for source: BindingSource,
        scope: Scope,
        isAvailable: (String) -> Bool
    ) -> (actions: [TargetChoice], elements: [TargetChoice], keyGroups: [TargetChoiceGroup]) {
        let actionChoices =
            PlayerActionRegistry.actions.map { action in
                let available = isAvailable(action.id)
                return TargetChoice(
                    title: action.localizedName,
                    blurb: action.localizedBlurb,
                    note: available ? nil : unavailableActionNote(action.id, in: .bindingList(scope)),
                    target: .action(action.id),
                    enabled: offersAction(available: available, scope: scope))
            } + [
                TargetChoice(
                    title: String(
                        localized: "Do nothing", comment: "Choice that makes a controller button do nothing."),
                    target: .unbound)
            ]
        // A key can stand in for a controller button, which hands it
        // every binding that button already has. An element cannot: a
        // chain of elements could loop.
        let elementChoices =
            source.isElement
            ? []
            : sections(includingOptional: []).flatMap(\.elements).map { row in
                TargetChoice(
                    title: row.label,
                    blurb: String(
                        localized: "Acts as this button",
                        comment: "Under a controller button name, in the list of what a key can do."),
                    target: .element(row.source.name))
            }
        let keyGroups = KeyCodePickerGroup.allCases.compactMap { group -> TargetChoiceGroup? in
            let codes = KeyCodeTable.codesByPickerGroup[group] ?? []
            guard !codes.isEmpty else { return nil }
            return TargetChoiceGroup(
                title: group.localizedTitle,
                choices: codes.map { code in
                    TargetChoice(
                        title: KeyCodeTable.displayName(for: code) ?? code,
                        blurb: group == .common ? commonKeyAnnotations[code] : nil,
                        target: .key(code))
                })
        }
        return (actionChoices, elementChoices, keyGroups)
    }

    static func resetMessage(scope: Scope, gameTitle: String?) -> LocalizedStringResource {
        switch scope {
        case .thisGame:
            if let gameTitle {
                return
                    "The buttons you changed for \(gameTitle) go back to their defaults. You can't undo this."
            }
            return "The buttons you changed for this game go back to their defaults. You can't undo this."
        case .allGames:
            return
                "The buttons you changed for all games go back to their defaults. Buttons you changed for one game stay. You can't undo this."
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

@MainActor
enum BindingsCatalog {

    /// The overrides that a binding screen changes.
    enum Scope: Hashable {
        case thisGame(GameContainer)
        case allGames

        var title: LocalizedStringResource {
            switch self {
            case .thisGame: "This game"
            case .allGames: "All games"
            }
        }

        var overrides: BindingMap? {
            switch self {
            case .thisGame(let container): BindingStore.loadPerGame(container: container)
            case .allGames: BindingStore.loadGlobal()
            }
        }

        /// An empty map removes the stored overrides.
        func store(_ map: BindingMap) {
            guard !map.entries.isEmpty else {
                deleteOverrides()
                return
            }
            switch self {
            case .thisGame(let container): BindingStore.savePerGame(container: container, map: map)
            case .allGames: BindingStore.saveGlobal(map)
            }
        }

        func deleteOverrides() {
            switch self {
            case .thisGame(let container): BindingStore.deletePerGame(container: container)
            case .allGames: BindingStore.deleteGlobal()
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
            result.append(Section(id: extrasSection.id, title: extrasSection.title, elements: extras))
        }
        return result
    }

    static func keyName(_ code: String) -> String {
        KeyCodeTable.displayName(for: code) ?? code
    }

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
            let name = keyName(code)
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

        init(scope: Scope, manifest: BindingMap?) {
            self.scope = scope
            self.manifest = manifest
            let global = BindingStore.loadGlobal()
            self.global = global
            switch scope {
            case .thisGame(let container):
                let perGame = BindingStore.loadPerGame(container: container)
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
            switch scope {
            case .thisGame: perGame != nil
            case .allGames: global != nil
            }
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
        switch target {
        case nil, .unbound?:
            return String(localized: "None", comment: "A controller button that does nothing.")
        case .key(let code)?:
            return keyName(code)
        case .element(let name)?:
            return label(for: .element(name))
        case .action(let name)?:
            // A newer Empo or a person wrote this action. The binding
            // stays in the map and does nothing.
            return EmpoActionCatalog.action(id: name)?.localizedName
                ?? String(localized: "Not supported in this version of Empo")
        }
    }

    static func save(source: BindingSource, target: BindingMap.Target, scope: Scope) {
        var map = scope.overrides ?? BindingMap()
        map.entries[source] = target
        scope.store(map)
    }

    static func removeOverride(source: BindingSource, scope: Scope) {
        var map = scope.overrides ?? BindingMap()
        map.entries.removeValue(forKey: source)
        scope.store(map)
    }

    static func resetTitle(scope: Scope) -> LocalizedStringResource {
        switch scope {
        case .thisGame: "Reset buttons for this game?"
        case .allGames: "Reset buttons for all games?"
        }
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

    static func unavailableActionNote(_ requirement: ActionRequirement, scope: Scope) -> String {
        switch (requirement, scope) {
        case (.cheats, .thisGame):
            String(localized: "This game has no cheats.")
        case (.fastForward, .thisGame):
            String(localized: "Fast forward is off for this game. Turn it on in this game's settings.")
        case (.cheats, .allGames):
            String(localized: "This game has no cheats. This button works in games that have cheats.")
        case (.fastForward, .allGames):
            String(
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
                    note: available
                        ? nil
                        : PlayerActionRegistry.requirement(of: action.id).map {
                            unavailableActionNote($0, scope: scope)
                        },
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
                        title: keyName(code),
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

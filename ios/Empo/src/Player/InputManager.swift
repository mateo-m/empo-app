// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

/// Sends the presses of one kind of physical input to the bound game
/// keys and actions. `Element` names one button or key of that input.
@MainActor
class InputManager<Element: Hashable> {
    /// Takes (action id, pressed). Returns false when the action
    /// refuses the press.
    var actionHandler: ((String, Bool) -> Bool)?

    /// Writes device lines to `controls.json.log`.
    var deviceLogHandler: ((String) -> Void)?

    /// While true, presses do not reach the game. Suppression swallows
    /// the release edges of the keys held when it begins. Release those
    /// keys now, or they stay stuck in the engine.
    var suppressInjection = false {
        didSet {
            if suppressInjection, !oldValue {
                releaseAllHeldInputs()
            }
        }
    }

    weak var overlay: OverlayVisibilityController?

    var sessionActive = false
    private(set) var resolvedMap: [Element: ResolvedTarget]

    /// A release repeats the press-time decision, also when the map
    /// changed while the element was down.
    private var pressedScancodes: [Element: Int32] = [:]
    private var pressedActions: [Element: String] = [:]

    private let keys: HeldKeys<KeyHolder>
    private let source: KeyHolder.Source
    private let holder: (Element) -> KeyHolder

    init(
        keys: HeldKeys<KeyHolder>,
        source: KeyHolder.Source,
        holder: @escaping (Element) -> KeyHolder,
        resolvedMap: [Element: ResolvedTarget] = [:]
    ) {
        self.keys = keys
        self.source = source
        self.holder = holder
        self.resolvedMap = resolvedMap
    }

    /// A held element keeps its press-time target until release.
    func updateResolvedMap(_ map: [Element: ResolvedTarget]) {
        resolvedMap = map
    }

    func press(_ element: Element, as target: ResolvedTarget) {
        switch target {
        case .key(let scancode):
            pressedScancodes[element] = scancode
            keys.hold(scancode, by: holder(element))
        case .action(let name):
            if actionHandler?(name, true) == true {
                pressedActions[element] = name
            }
        case .unbound:
            break
        }
    }

    func release(_ element: Element) {
        if let action = pressedActions.removeValue(forKey: element) {
            _ = actionHandler?(action, false)
            return
        }
        guard let scancode = pressedScancodes.removeValue(forKey: element) else { return }
        keys.release(scancode, by: holder(element))
    }

    /// Suppression and `stop()` swallow the physical release edges. A
    /// held fast-forward with no release leaves the engine sped up.
    func releaseAllHeldInputs() {
        keys.release { $0.source == source }
        pressedScancodes.removeAll()

        for action in pressedActions.values {
            _ = actionHandler?(action, false)
        }
        pressedActions.removeAll()
    }
}

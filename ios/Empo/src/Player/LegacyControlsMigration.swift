// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

/// The layout that UserDefaults held before the controls file.
private struct LegacyLayout: Decodable {
    struct DPad: Decodable {
        var rx: CGFloat
        var ry: CGFloat
        var size: CGFloat
        var opacity: Double?
    }
    struct Oriented: Decodable {
        var dpad: DPad
        var buttons: [LegacyButton]
    }
    var portrait: Oriented
    var landscape: Oriented
}

private struct LegacyLayoutV1: Decodable {
    var dpad: LegacyLayout.DPad
    var buttons: [LegacyButton]
}

private struct LegacyButton: Decodable {
    var label = ""
    var scancode: Int32 = 0
    var rx: CGFloat = 0.5
    var ry: CGFloat = 0.5
    var size = CGFloat(ControlLimits.defaultButtonSize)
    var opacity = 1.0

    enum CodingKeys: String, CodingKey {
        case label, scancode, rx, ry, size, opacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? label
        scancode = try c.decodeIfPresent(Int32.self, forKey: .scancode) ?? scancode
        rx = try c.decodeIfPresent(CGFloat.self, forKey: .rx) ?? rx
        ry = try c.decodeIfPresent(CGFloat.self, forKey: .ry) ?? ry
        size = try c.decodeIfPresent(CGFloat.self, forKey: .size) ?? size
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
    }
}

/// Moves the layout and the bindings of a game from UserDefaults to
/// its controls file.
@MainActor
enum LegacyControlsMigration {
    /// A backup run calls this before it stages `EmpoState/`. Thus a
    /// game that the player did not open since the update also moves
    /// its layout into the container.
    static func run(container: GameContainer, keys: [GameKey]) {
        guard !UserControlsFile.exists(in: container) else { return }

        let layoutKey = DefaultsKey.controlsLayout(gameID: container.id)
        let mapKey = DefaultsKey.controllerMap(gameID: container.id)
        let layoutData = UserDefaults.standard.data(forKey: layoutKey)
        let hasMap = UserDefaults.standard.data(forKey: mapKey) != nil
        guard layoutData != nil || hasMap else { return }

        let touch = layoutData.flatMap { legacyTouchSection(data: $0, keys: keys) }
        let controller = BindingStore.decodeLegacyPerGameMap(gameID: container.id)

        guard touch != nil || controller != nil else { return }

        guard UserControlsFile.write(in: container, touch: touch, bindings: controller) else {
            return
        }

        // The controls file stops the next run, so a key that gave
        // nothing to move keeps its bytes.
        if touch != nil { UserDefaults.standard.removeObject(forKey: layoutKey) }
        if controller != nil { UserDefaults.standard.removeObject(forKey: mapKey) }
    }

    /// The legacy blob has no action buttons, so the section leaves the
    /// key out and the layout inherits the shipped ones.
    private static func legacyTouchSection(data: Data, keys: [GameKey]) -> TouchSection? {
        func layout(_ dpad: LegacyLayout.DPad, _ buttons: [LegacyButton]) -> TouchLayout {
            TouchLayout(
                dpad: DPadSpec(
                    x: Double(dpad.rx), y: Double(dpad.ry), size: Double(dpad.size),
                    opacity: dpad.opacity ?? 1.0),
                buttons: buttons.compactMap { button in
                    guard let key = KeyCodeTable.code(for: button.scancode) else {
                        NSLog(
                            "controls.json: Dropped button \"\(button.label)\" (scancode \(button.scancode) has no key name)"
                        )
                        return nil
                    }
                    return ButtonSpec(
                        label: button.label, key: key, x: Double(button.rx), y: Double(button.ry),
                        size: Double(button.size), opacity: button.opacity)
                })
        }
        if let v2 = try? JSONDecoder().decode(LegacyLayout.self, from: data) {
            return TouchSection(
                portrait: layout(v2.portrait.dpad, v2.portrait.buttons),
                landscape: layout(v2.landscape.dpad, v2.landscape.buttons))
        }
        if let v1 = try? JSONDecoder().decode(LegacyLayoutV1.self, from: data) {
            var landscape = LayoutProfilesManager.builtins(keys: keys).landscape
            landscape.actionButtons = nil
            return TouchSection(portrait: layout(v1.dpad, v1.buttons), landscape: landscape)
        }
        return nil
    }
}

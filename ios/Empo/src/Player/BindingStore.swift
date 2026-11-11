// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

extension Notification.Name {
    static let bindingsDidChange = Notification.Name("bindingsDidChange")

    static let gameAreaTouchBegan = Notification.Name("gameAreaTouchBegan")
}

enum BindingStore {
    static func loadGlobal() -> BindingMap? {
        guard let map = load(key: DefaultsKey.controllerMapGlobal) else { return nil }
        // Write quietly. A change notification here calls this load again.
        let migrated = EmpoActionCatalog.migrated(map)
        if migrated.changed {
            saveQuietly(migrated.map, key: DefaultsKey.controllerMapGlobal)
        }
        return migrated.map
    }

    static func saveGlobal(_ map: BindingMap) {
        save(map, key: DefaultsKey.controllerMapGlobal)
    }

    static func loadPerGame(container: GameContainer) -> BindingMap? {
        UserControlsFile.acceptedManifest(in: container)?.bindings
    }

    static func savePerGame(container: GameContainer, map: BindingMap) {
        let controller = map.entries.isEmpty ? nil : map
        _ = UserControlsFile.updateBindings(in: container, bindings: controller)
        NotificationCenter.default.post(name: .bindingsDidChange, object: nil)
    }

    static func deleteGlobal() {
        delete(key: DefaultsKey.controllerMapGlobal)
    }

    static func deletePerGame(container: GameContainer) {
        _ = UserControlsFile.removeBindingsSection(in: container)
        NotificationCenter.default.post(name: .bindingsDidChange, object: nil)
    }

    private static func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .bindingsDidChange, object: nil)
    }

    private static func load(key: String) -> BindingMap? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let map = BindingMapCoder.decode(object) { source, issue in
            NSLog("bindings: dropped \(source) from stored map (\(issue))")
        }
        return map.entries.isEmpty ? nil : map
    }

    private static func save(_ map: BindingMap, key: String) {
        saveQuietly(map, key: key)
        NotificationCenter.default.post(name: .bindingsDidChange, object: nil)
    }

    private static func saveQuietly(_ map: BindingMap, key: String) {
        let object = BindingMapCoder.encode(map)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// This write posts no change notification. The caller reloads after it.
    static func migrateRenamedActions(container: GameContainer) {
        guard let result = UserControlsFile.load(in: container),
            let controller = result.manifest?.bindings
        else { return }
        let migrated = EmpoActionCatalog.migrated(controller)
        guard migrated.changed else { return }
        _ = UserControlsFile.updateBindings(in: container, bindings: migrated.map)
    }

    static func decodeLegacyPerGameMap(gameID: String) -> BindingMap? {
        load(key: DefaultsKey.controllerMap(gameID: gameID))
    }
}

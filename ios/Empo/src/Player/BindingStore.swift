// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

extension Notification.Name {
    static let bindingsDidChange = Notification.Name("bindingsDidChange")
}

enum BindingStore {
    static func loadGlobal() -> BindingMap? {
        guard let map = load(key: DefaultsKey.controllerMapGlobal) else { return nil }
        return migrated(map) { saveQuietly($0, key: DefaultsKey.controllerMapGlobal) }
    }

    static func saveGlobal(_ map: BindingMap) {
        save(map, key: DefaultsKey.controllerMapGlobal)
    }

    static func loadPerGame(container: GameContainer) -> BindingMap? {
        guard let map = UserControlsFile.acceptedManifest(in: container)?.bindings else { return nil }
        return migrated(map) { _ = try? UserControlsFile.updateBindings(in: container, bindings: $0) }
    }

    /// The write must not post a change notification, because the
    /// notification calls the load again.
    private static func migrated(_ map: BindingMap, write: (BindingMap) -> Void) -> BindingMap {
        let migrated = EmpoActionCatalog.migrated(map)
        if migrated.changed {
            write(migrated.map)
        }
        return migrated.map
    }

    static func savePerGame(container: GameContainer, map: BindingMap) throws(UserControlsFile.SaveRefusal) {
        let controller = map.entries.isEmpty ? nil : map
        _ = try UserControlsFile.updateBindings(in: container, bindings: controller)
        NotificationCenter.default.post(name: .bindingsDidChange, object: nil)
    }

    static func deleteGlobal() {
        delete(key: DefaultsKey.controllerMapGlobal)
    }

    static func deletePerGame(container: GameContainer) throws(UserControlsFile.SaveRefusal) {
        _ = try UserControlsFile.updateBindings(in: container, bindings: nil)
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

    static func decodeLegacyPerGameMap(gameID: String) -> BindingMap? {
        load(key: DefaultsKey.controllerMap(gameID: gameID))
    }
}

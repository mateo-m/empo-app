import Foundation
import GameProbe

extension Notification.Name {
    /// The store posts this after it saves a global or per-game controller map.
    static let controllerMapDidChange = Notification.Name("controllerMapDidChange")

    /// The app posts this when a touch begins on the embedded SDL game view during play.
    static let gameAreaTouchBegan = Notification.Name("gameAreaTouchBegan")
}

/// UserDefaults persistence for global controller overrides. Per-game overrides
/// live in `EmpoState/controls.json` (SPEC §3, ticket 009).
enum ControllerMapStore {
    static func loadGlobal() -> ControllerMap? {
        guard let map = load(key: DefaultsKey.controllerMapGlobal) else { return nil }
        // One-time rename migration for Empo-owned storage. Quiet
        // write: a change notification here would re-enter this load.
        let migrated = EmpoActionCatalog.migrated(map)
        if migrated.changed {
            saveQuietly(migrated.map, key: DefaultsKey.controllerMapGlobal)
        }
        return migrated.map
    }

    static func saveGlobal(_ map: ControllerMap) {
        save(map, key: DefaultsKey.controllerMapGlobal)
    }

    static func loadPerGame(container: GameContainer) -> ControllerMap? {
        guard let result = UserControlsFile.load(in: container) else { return nil }
        guard !result.findings.contains(where: { $0.severity == .error }) else { return nil }
        return result.manifest?.controller
    }

    static func savePerGame(container: GameContainer, map: ControllerMap) {
        let controller = map.entries.isEmpty ? nil : map
        _ = UserControlsFile.updateController(in: container, controller: controller)
        NotificationCenter.default.post(name: .controllerMapDidChange, object: nil)
    }

    static func deleteGlobal() {
        delete(key: DefaultsKey.controllerMapGlobal)
    }

    static func deletePerGame(container: GameContainer) {
        _ = UserControlsFile.removeControllerSection(in: container)
        NotificationCenter.default.post(name: .controllerMapDidChange, object: nil)
    }

    private static func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .controllerMapDidChange, object: nil)
    }

    private static func load(key: String) -> ControllerMap? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        var entries: [String: ControllerMap.Target] = [:]
        for (element, value) in object {
            guard ControllerElement.allNames.contains(element) else { continue }
            if value is NSNull {
                entries[element] = .unbound
                continue
            }
            guard let text = value as? String else { continue }
            if text.hasPrefix("$") {
                // Unknown actions stay in the map (inert at dispatch)
                // so a load-modify-save cycle cannot strip them. Same
                // rule as the file loader's W005.
                entries[element] = .action(text)
            } else if KeyCodeTable.scancode(for: text) != nil {
                entries[element] = .key(text)
            }
        }
        return entries.isEmpty ? nil : ControllerMap(entries: entries)
    }

    private static func save(_ map: ControllerMap, key: String) {
        saveQuietly(map, key: key)
        NotificationCenter.default.post(name: .controllerMapDidChange, object: nil)
    }

    private static func saveQuietly(_ map: ControllerMap, key: String) {
        var object: [String: Any] = [:]
        for (element, target) in map.entries {
            switch target {
            case .key(let code):
                object[element] = code
            case .action(let name):
                object[element] = name
            case .unbound:
                object[element] = NSNull()
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// One-time rename migration for the per-game controller section.
    /// Runs at game selection. Quiet: the caller reloads afterwards.
    static func migrateRenamedActions(container: GameContainer) {
        guard let result = UserControlsFile.load(in: container),
            let controller = result.manifest?.controller
        else { return }
        let migrated = EmpoActionCatalog.migrated(controller)
        guard migrated.changed else { return }
        _ = UserControlsFile.updateController(in: container, controller: migrated.map)
    }

    /// Decode a legacy per-game controller map from UserDefaults (migration only).
    static func decodeLegacyPerGameMap(gameID: String) -> ControllerMap? {
        load(key: DefaultsKey.controllerMap(gameID: gameID))
    }
}

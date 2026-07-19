import Foundation
import GameProbe

extension Notification.Name {
    /// Posted after a global or per-game controller map is saved.
    static let controllerMapDidChange = Notification.Name("controllerMapDidChange")
}

/// UserDefaults persistence for controller map overrides (SPEC §3, §7).
/// JSON shape matches manifest `controller` objects for future export/import.
enum ControllerMapStore {
    private static let knownActions: Set<String> = [
        "$pauseMenu",
        "$toggleOverlay",
    ]

    static func loadGlobal() -> ControllerMap? {
        load(key: DefaultsKey.controllerMapGlobal)
    }

    static func saveGlobal(_ map: ControllerMap) {
        save(map, key: DefaultsKey.controllerMapGlobal)
    }

    static func loadPerGame(gameID: String) -> ControllerMap? {
        load(key: DefaultsKey.controllerMap(gameID: gameID))
    }

    static func savePerGame(gameID: String, map: ControllerMap) {
        save(map, key: DefaultsKey.controllerMap(gameID: gameID))
    }

    static func deleteGlobal() {
        delete(key: DefaultsKey.controllerMapGlobal)
    }

    static func deletePerGame(gameID: String) {
        delete(key: DefaultsKey.controllerMap(gameID: gameID))
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
                guard knownActions.contains(text) else { continue }
                entries[element] = .action(text)
            } else if KeyCodeTable.scancode(for: text) != nil {
                entries[element] = .key(text)
            }
        }
        return entries.isEmpty ? nil : ControllerMap(entries: entries)
    }

    private static func save(_ map: ControllerMap, key: String) {
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
        NotificationCenter.default.post(name: .controllerMapDidChange, object: nil)
    }
}

import Foundation
import GameProbe

extension Notification.Name {
    /// Posted after a global or per-game controller map is saved.
    static let controllerMapDidChange = Notification.Name("controllerMapDidChange")
}

/// UserDefaults persistence for global controller overrides; per-game overrides
/// live in `EmpoState/controls.json` (SPEC §3, ticket 009).
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

    /// Decode a legacy per-game controller map from UserDefaults (migration only).
    static func decodeLegacyPerGameMap(gameID: String) -> ControllerMap? {
        load(key: DefaultsKey.controllerMap(gameID: gameID))
    }
}

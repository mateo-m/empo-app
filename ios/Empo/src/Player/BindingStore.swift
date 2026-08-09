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
enum BindingStore {
    static func loadGlobal() -> BindingMap? {
        guard let map = load(key: DefaultsKey.controllerMapGlobal) else { return nil }
        // One-time rename migration for Empo-owned storage. Quiet
        // write: a change notification here would re-enter this load.
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
        guard let result = UserControlsFile.load(in: container) else { return nil }
        guard !result.findings.contains(where: { $0.severity == .error }) else { return nil }
        return result.manifest?.bindings
    }

    static func savePerGame(container: GameContainer, map: BindingMap) {
        let controller = map.entries.isEmpty ? nil : map
        _ = UserControlsFile.updateBindings(in: container, bindings: controller)
        NotificationCenter.default.post(name: .controllerMapDidChange, object: nil)
    }

    static func deleteGlobal() {
        delete(key: DefaultsKey.controllerMapGlobal)
    }

    static func deletePerGame(container: GameContainer) {
        _ = UserControlsFile.removeBindingsSection(in: container)
        NotificationCenter.default.post(name: .controllerMapDidChange, object: nil)
    }

    private static func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .controllerMapDidChange, object: nil)
    }

    private static func load(key: String) -> BindingMap? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        var entries: [String: BindingMap.Target] = [:]
        for (source, value) in object {
            let isElement = ControllerElement.allNames.contains(source)
            guard isElement || KeyCodeTable.scancode(for: source) != nil else { continue }
            if value is NSNull {
                entries[source] = .unbound
                continue
            }
            guard let text = value as? String else { continue }
            if text.hasPrefix("$") {
                // Unknown actions stay in the map (inert at dispatch)
                // so a load-modify-save cycle cannot strip them. Same
                // rule as the file loader's W005.
                entries[source] = .action(text)
            } else if KeyCodeTable.scancode(for: text) != nil {
                entries[source] = .key(text)
            } else if ControllerElement.allNames.contains(text), !isElement {
                // A key standing in for a pad button. Elements cannot
                // chain to elements; the loader rejects that (V023).
                entries[source] = .element(text)
            }
        }
        return entries.isEmpty ? nil : BindingMap(entries: entries)
    }

    private static func save(_ map: BindingMap, key: String) {
        saveQuietly(map, key: key)
        NotificationCenter.default.post(name: .controllerMapDidChange, object: nil)
    }

    private static func saveQuietly(_ map: BindingMap, key: String) {
        var object: [String: Any] = [:]
        for (source, target) in map.entries {
            switch target {
            case .key(let code):
                object[source] = code
            case .element(let name):
                object[source] = name
            case .action(let name):
                object[source] = name
            case .unbound:
                object[source] = NSNull()
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// One-time rename migration for the per-game controller section.
    /// Runs at game selection. Quiet: the caller reloads afterwards.
    static func migrateRenamedActions(container: GameContainer) {
        guard let result = UserControlsFile.load(in: container),
            let controller = result.manifest?.bindings
        else { return }
        let migrated = EmpoActionCatalog.migrated(controller)
        guard migrated.changed else { return }
        _ = UserControlsFile.updateBindings(in: container, bindings: migrated.map)
    }

    /// Decode a legacy per-game controller map from UserDefaults (migration only).
    static func decodeLegacyPerGameMap(gameID: String) -> BindingMap? {
        load(key: DefaultsKey.controllerMap(gameID: gameID))
    }
}

import Foundation
import GameProbe

extension Notification.Name {
    /// The store posts this after it saves a global or per-game controller map.
    static let bindingsDidChange = Notification.Name("bindingsDidChange")

    /// The app posts this when a touch begins on the embedded SDL game view during play.
    static let gameAreaTouchBegan = Notification.Name("gameAreaTouchBegan")
}

/// UserDefaults persistence for global binding overrides. Per-game
/// overrides live in `EmpoState/controls.json` (SPEC section 3, ticket 009).
///
/// The stored shape is the manifest's own bindings object, read and
/// written by `BindingMapCoder`, so a binding means the same thing
/// here as it does in a file a game ships.
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
            // Empo owns this file, so a rejected entry means a hand
            // edit or an older shape. The manifest log is per game.
            // This one is global, so it goes to the console.
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

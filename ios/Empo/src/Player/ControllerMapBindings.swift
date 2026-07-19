import Foundation
import GameProbe

/// Builds controller map override layers and applies them to the session
/// input manager (SPEC §9). Call on game select and override changes.
@MainActor
enum ControllerMapBindings {
    static func overrideLayers(for gameID: String?) -> [ControllerMap] {
        var layers: [ControllerMap] = []
        if let global = ControllerMapStore.loadGlobal() {
            layers.append(global)
        }
        if let controller = ControlsLayout.shared.activeManifest?.controller {
            layers.append(controller)
        }
        if let gameID, let perGame = ControllerMapStore.loadPerGame(gameID: gameID) {
            layers.append(perGame)
        }
        return layers
    }

    static func applyRuntimeMap(to manager: ControllerInputManager, gameID: String?) {
        manager.updateResolvedMap(
            ControllerMapResolver.resolvedRuntimeMap(layers: overrideLayers(for: gameID)))
    }
}

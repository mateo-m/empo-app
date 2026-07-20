import Foundation
import GameProbe

/// Builds controller map override layers and applies them to the session
/// input manager (SPEC §9). Call on game select and override changes.
@MainActor
enum ControllerMapBindings {
    static func overrideLayers(for container: GameContainer?) -> [ControllerMap] {
        var layers: [ControllerMap] = []
        if let global = ControllerMapStore.loadGlobal() {
            layers.append(global)
        }
        if let controller = ControlsLayout.shared.activeManifest?.controller {
            layers.append(controller)
        }
        if let container, let perGame = ControllerMapStore.loadPerGame(container: container) {
            layers.append(perGame)
        }
        return layers
    }

    static func applyRuntimeMap(to manager: ControllerInputManager, container: GameContainer?) {
        manager.updateResolvedMap(
            ControllerMapResolver.resolvedRuntimeMap(layers: overrideLayers(for: container)))
    }
}

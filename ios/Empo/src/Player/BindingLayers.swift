import Foundation
import GameProbe

/// Builds binding override layers and applies them to the session
/// input managers (SPEC §9). Call on game select and override changes.
@MainActor
enum BindingLayers {
    static func overrideLayers(for container: GameContainer?) -> [BindingMap] {
        var layers: [BindingMap] = []
        if let global = BindingStore.loadGlobal() {
            layers.append(global)
        }
        if let manifest = ControlsLayout.shared.activeManifest?.bindings {
            layers.append(manifest)
        }
        if let container, let perGame = BindingStore.loadPerGame(container: container) {
            layers.append(perGame)
        }
        return layers
    }

    static func applyRuntimeMap(to manager: ControllerInputManager, container: GameContainer?) {
        manager.updateResolvedMap(
            BindingResolver.resolvedRuntimeMap(layers: overrideLayers(for: container)))
    }

    static func applyRuntimeMap(to manager: KeyboardInputManager, container: GameContainer?) {
        manager.updateResolvedMap(
            BindingResolver.resolvedKeyMap(layers: overrideLayers(for: container)))
    }
}

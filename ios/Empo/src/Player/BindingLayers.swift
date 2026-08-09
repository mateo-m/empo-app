import Foundation
import GameProbe

/// Builds the binding override layers, newest last (SPEC §9).
/// `SessionInput` resolves them once and hands each runtime map to
/// the path that reads it.
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
}

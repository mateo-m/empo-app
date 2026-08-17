import GameProbe
import SwiftUI

/// The session's physical input: a controller path, a keyboard path,
/// and the overlay rule they both feed.
///
/// The player screen talks to this, not to the managers. Anything a
/// session does to input (start, stop, rebind, suppress) is one
/// call here instead of one call per device kind.
@MainActor
final class SessionInput {
    let controller = ControllerInputManager()
    let keyboard = KeyboardInputManager()
    private let overlay = OverlayVisibilityController()

    init() {
        controller.overlay = overlay
        keyboard.overlay = overlay
    }

    /// Dispatches action targets from either path: (action id, pressed).
    var actionHandler: ((String, Bool) -> Void)? {
        didSet {
            controller.actionHandler = actionHandler
            keyboard.actionHandler = actionHandler
        }
    }

    /// Device connects, for `controls.json.log`.
    var deviceLogHandler: ((String) -> Void)? {
        didSet {
            controller.deviceLogHandler = deviceLogHandler
            keyboard.deviceLogHandler = deviceLogHandler
        }
    }

    /// True while the game asks for text. The keyboard passes keys
    /// through unmapped, so the player types what they typed.
    var textInputActive = false {
        didSet { keyboard.textInputActive = textInputActive }
    }

    /// The remap screen is frontmost: read edges, inject nothing.
    var suppressInjection = false {
        didSet {
            controller.suppressInjection = suppressInjection
            keyboard.suppressInjection = suppressInjection
        }
    }

    /// Whether this session has seen anything worth remapping.
    var hasSeenPhysicalInput: Bool {
        controller.hasHadControllerThisSession || keyboard.hasHadKeyboardThisSession
    }

    func start(overlayHidden: Binding<Bool>, editMode: Binding<Bool>) {
        overlay.bind(hidden: overlayHidden, editMode: editMode)
        controller.start()
        keyboard.start()
    }

    func stop() {
        controller.stop()
        keyboard.stop()
        overlay.unbind()
    }

    /// Rebuilds both runtime maps from one merge of the layers.
    func applyBindings(container: GameContainer?) {
        let runtime = BindingResolver.resolveRuntime(
            layers: BindingLayers.overrideLayers(for: container))
        controller.updateResolvedMap(runtime.elements)
        keyboard.updateResolvedMap(runtime.keys)
    }

    /// The player toggled overlay visibility by hand.
    func noteManualOverlayToggle() {
        overlay.update { $0.noteManualToggle() }
    }
}

import Foundation
import GameController
import GameProbe

/// Host-side physical controller input (SPEC §10.2). Maps GCController
/// elements to keyboard scancodes via the merged four-layer map (§9).
@MainActor
final class ControllerInputManager {
    /// Dispatches action targets: (action id, pressed). Wired to
    /// `PlayerActionRegistry.handle`. Hold actions rely on the
    /// release edge; see `releaseAllHeldKeys` for the paths where
    /// release edges cannot arrive.
    var actionHandler: ((String, Bool) -> Void)?

    /// Runs on physical element press edges (listen mode for the remap UI).
    var elementActivityHandler: ((String) -> Void)?

    /// When true, edges still update internal state but do not inject keys
    /// or dispatch host actions (remap screen is frontmost). When
    /// suppression begins, the manager releases the keys held at that
    /// moment. Their swallowed release edges then cannot leave the
    /// engine with a stuck key.
    var suppressInjection = false {
        didSet {
            if suppressInjection, !oldValue {
                releaseAllHeldInputs()
            }
        }
    }

    /// The session's overlay rule. The manager reports facts to it
    /// and never writes the player's visibility flag itself.
    weak var overlay: OverlayVisibilityController?

    /// True once any controller has connected during this session.
    private(set) var hasHadControllerThisSession = false

    /// SDL element names for optional hardware (paddles, touchpad) that
    /// at least one currently connected controller exposes.
    var exposedOptionalElements: Set<String> {
        var exposed = Set<String>()
        for controller in connectedControllers.values {
            guard let gamepad = controller.extendedGamepad else { continue }
            if let xbox = gamepad as? GCXboxGamepad {
                if xbox.paddleButton1 != nil { exposed.insert("paddle1") }
                if xbox.paddleButton2 != nil { exposed.insert("paddle2") }
                if xbox.paddleButton3 != nil { exposed.insert("paddle3") }
                if xbox.paddleButton4 != nil { exposed.insert("paddle4") }
            } else if gamepad is GCDualSenseGamepad {
                exposed.insert("touchpad")
            }
        }
        return exposed
    }

    private var sessionActive = false
    private var reducer = ControllerStateReducer()
    private var resolvedMap = BindingResolver.resolveRuntime().elements
    private var elementPressScancode: [String: Int32] = [:]
    // element -> action id held by that element, mirroring
    // elementPressScancode so hold actions get their release edge.
    private var elementPressAction: [String: String] = [:]
    private var connectedControllers: [ObjectIdentifier: GCController] = [:]

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    /// Atomically swap the merged map. Keys held mid-press keep their
    /// press-time scancode until release (SPEC §10.2 / ticket 004).
    func updateResolvedMap(_ map: [String: ResolvedTarget]) {
        resolvedMap = map
    }

    func start() {
        stop()
        sessionActive = true
        hasHadControllerThisSession = false

        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            Task { @MainActor in
                self?.attach(controller)
            }
        }

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            Task { @MainActor in
                self?.detach(controller)
            }
        }

        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    func stop() {
        sessionActive = false
        releaseAllHeldInputs()

        if let connectObserver {
            NotificationCenter.default.removeObserver(connectObserver)
        }
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
        connectObserver = nil
        disconnectObserver = nil

        for controller in connectedControllers.values {
            controller.extendedGamepad?.valueChangedHandler = nil
            controller.physicalInputProfile.valueDidChangeHandler = nil
        }
        connectedControllers.removeAll()
        reducer = ControllerStateReducer()
        elementPressScancode.removeAll()
        elementPressAction.removeAll()
    }

    /// Reports every connected device to `controls.json.log`, whether
    /// or not the mapper can use it. A bug report about a controller
    /// that "does nothing" is unanswerable without this: it tells
    /// apart a pad iOS never exposed, a pad with element names Empo
    /// does not know, and a pad that works but is bound elsewhere.
    var deviceLogHandler: ((String) -> Void)?

    private func logDevice(_ controller: GCController) {
        guard let deviceLogHandler else { return }
        let profile = controller.physicalInputProfile
        let elements = profile.elements.keys.sorted().joined(separator: ", ")
        deviceLogHandler(
            """
            controller connected: \(controller.vendorName ?? "unnamed") \
            [\(controller.productCategory)] \
            extended=\(controller.extendedGamepad != nil) \
            micro=\(controller.microGamepad != nil) \
            mappable=\(Self.isMappable(controller)) \
            elements=[\(elements)]
            """
        )
    }

    private func attach(_ controller: GCController) {
        guard sessionActive else { return }
        logDevice(controller)
        guard Self.isMappable(controller) else { return }
        let id = ObjectIdentifier(controller)
        guard connectedControllers[id] == nil else {
            installHandler(on: controller)
            return
        }

        let priorCount = connectedControllers.count
        connectedControllers[id] = controller
        hasHadControllerThisSession = true
        installHandler(on: controller)

        overlay?.update {
            $0.setExtendedController(hasExtendedController, isFirstController: priorCount == 0)
        }
    }

    /// A controller is mappable when it has the extended profile, or
    /// when its physical input profile has at least one element the
    /// profile path feeds (named button, trigger, dpad, or stick).
    /// This admits the basic and micro profiles without the
    /// deprecated `GCController.gamepad` accessor, and rejects
    /// devices with only vendor-named elements the mapper cannot
    /// use.
    private static func isMappable(_ controller: GCController) -> Bool {
        if controller.extendedGamepad != nil { return true }
        let profile = controller.physicalInputProfile
        if profileButtonElements.contains(where: { profile.buttons[$0.name] != nil }) {
            return true
        }
        if profile.buttons[GCInputLeftTrigger] != nil
            || profile.buttons[GCInputRightTrigger] != nil
        {
            return true
        }
        return profile.dpads[GCInputDirectionPad] != nil
            || profile.dpads[GCInputLeftThumbstick] != nil
            || profile.dpads[GCInputRightThumbstick] != nil
    }

    private func detach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard connectedControllers[id] != nil else { return }
        let hadExtendedController = hasExtendedController
        connectedControllers.removeValue(forKey: id)

        controller.extendedGamepad?.valueChangedHandler = nil
        controller.physicalInputProfile.valueDidChangeHandler = nil
        let edges = reducer.removeController(String(id.hashValue))
        dispatch(edges: edges)

        if connectedControllers.isEmpty {
            overlay?.update { $0.noteAllControllersDisconnected() }
        } else if hadExtendedController != hasExtendedController {
            overlay?.update { $0.setExtendedController(hasExtendedController) }
        }
    }

    private var hasExtendedController: Bool {
        connectedControllers.values.contains { $0.extendedGamepad != nil }
    }

    private func installHandler(on controller: GCController) {
        let controllerID = String(ObjectIdentifier(controller).hashValue)

        // Clear both handler paths first so a reinstall is
        // idempotent: exactly one path is active per controller.
        controller.extendedGamepad?.valueChangedHandler = nil
        controller.physicalInputProfile.valueDidChangeHandler = nil

        if let gamepad = controller.extendedGamepad {
            gamepad.valueChangedHandler = { [weak self] pad, _ in
                Task { @MainActor in
                    self?.pollGamepad(controllerID: controllerID, gamepad: pad)
                }
            }
            pollGamepad(controllerID: controllerID, gamepad: gamepad)
        } else {
            // Basic and micro profiles miss the typed extended API. Read
            // them through the element dictionaries instead, which the
            // framework keys with the same GCInput names on every
            // profile. The profile handler reports each element change;
            // per-frame polling is not necessary and GameController
            // documents that handlers are the correct pattern.
            let profile = controller.physicalInputProfile
            profile.valueDidChangeHandler = { [weak self] profile, _ in
                Task { @MainActor in
                    self?.pollProfile(controllerID: controllerID, profile: profile)
                }
            }
            pollProfile(controllerID: controllerID, profile: profile)
        }
    }

    private func pollGamepad(controllerID: String, gamepad: GCExtendedGamepad) {
        guard sessionActive, isAttached(gamepad.controller) else { return }

        feedButton(controllerID: controllerID, element: "a", pressed: gamepad.buttonA.isPressed)
        feedButton(controllerID: controllerID, element: "b", pressed: gamepad.buttonB.isPressed)
        feedButton(controllerID: controllerID, element: "x", pressed: gamepad.buttonX.isPressed)
        feedButton(controllerID: controllerID, element: "y", pressed: gamepad.buttonY.isPressed)
        feedButton(
            controllerID: controllerID, element: "leftshoulder", pressed: gamepad.leftShoulder.isPressed)
        feedButton(
            controllerID: controllerID, element: "rightshoulder", pressed: gamepad.rightShoulder.isPressed
        )
        feedButton(controllerID: controllerID, element: "lefttrigger", value: gamepad.leftTrigger.value)
        feedButton(
            controllerID: controllerID, element: "righttrigger", value: gamepad.rightTrigger.value)
        feedButton(controllerID: controllerID, element: "start", pressed: gamepad.buttonMenu.isPressed)
        feedButton(
            controllerID: controllerID, element: "back",
            pressed: gamepad.buttonOptions?.isPressed ?? false)
        feedButton(
            controllerID: controllerID, element: "guide", pressed: gamepad.buttonHome?.isPressed ?? false)
        feedButton(
            controllerID: controllerID, element: "leftstick",
            pressed: gamepad.leftThumbstickButton?.isPressed ?? false)
        feedButton(
            controllerID: controllerID, element: "rightstick",
            pressed: gamepad.rightThumbstickButton?.isPressed ?? false)

        let dpad = gamepad.dpad
        feedButton(controllerID: controllerID, element: "dpup", pressed: dpad.up.isPressed)
        feedButton(controllerID: controllerID, element: "dpdown", pressed: dpad.down.isPressed)
        feedButton(controllerID: controllerID, element: "dpleft", pressed: dpad.left.isPressed)
        feedButton(controllerID: controllerID, element: "dpright", pressed: dpad.right.isPressed)

        for sample in ControllerStickMapper.halfAxisSamples(
            stick: "left",
            x: Float(gamepad.leftThumbstick.xAxis.value),
            y: Float(gamepad.leftThumbstick.yAxis.value)
        ) {
            feedAxis(controllerID: controllerID, element: sample.element, value: sample.value)
        }

        for sample in ControllerStickMapper.halfAxisSamples(
            stick: "right",
            x: Float(gamepad.rightThumbstick.xAxis.value),
            y: Float(gamepad.rightThumbstick.yAxis.value)
        ) {
            feedAxis(controllerID: controllerID, element: sample.element, value: sample.value)
        }

        feedOptionalPaddles(controllerID: controllerID, gamepad: gamepad)
    }

    /// Named elements the profile path maps to SDL element names. The
    /// GCInput constants are the same strings on every profile, so the
    /// reducer, the resolved map, and the remap UI see one vocabulary
    /// for all controller classes.
    private static let profileButtonElements: [(name: String, element: String)] = [
        (GCInputButtonA, "a"), (GCInputButtonB, "b"),
        (GCInputButtonX, "x"), (GCInputButtonY, "y"),
        (GCInputLeftShoulder, "leftshoulder"), (GCInputRightShoulder, "rightshoulder"),
        (GCInputButtonMenu, "start"), (GCInputButtonOptions, "back"),
        (GCInputButtonHome, "guide"),
        (GCInputLeftThumbstickButton, "leftstick"), (GCInputRightThumbstickButton, "rightstick"),
    ]

    /// Feeds a controller without the extended profile. Only the
    /// elements the hardware exposes get fed; absent names stay
    /// untouched so the reducer never sees false releases.
    private func pollProfile(controllerID: String, profile: GCPhysicalInputProfile) {
        guard sessionActive, isAttached(profile.device as? GCController) else { return }

        for entry in Self.profileButtonElements {
            if let button = profile.buttons[entry.name] {
                feedButton(controllerID: controllerID, element: entry.element, pressed: button.isPressed)
            }
        }

        // Triggers are analog. Feed the raw value so the reducer
        // applies the same hysteresis as on the extended path.
        if let trigger = profile.buttons[GCInputLeftTrigger] {
            feedButton(controllerID: controllerID, element: "lefttrigger", value: trigger.value)
        }
        if let trigger = profile.buttons[GCInputRightTrigger] {
            feedButton(controllerID: controllerID, element: "righttrigger", value: trigger.value)
        }

        if let dpad = profile.dpads[GCInputDirectionPad] {
            feedButton(controllerID: controllerID, element: "dpup", pressed: dpad.up.isPressed)
            feedButton(controllerID: controllerID, element: "dpdown", pressed: dpad.down.isPressed)
            feedButton(controllerID: controllerID, element: "dpleft", pressed: dpad.left.isPressed)
            feedButton(controllerID: controllerID, element: "dpright", pressed: dpad.right.isPressed)
        }

        if let stick = profile.dpads[GCInputLeftThumbstick] {
            for sample in ControllerStickMapper.halfAxisSamples(
                stick: "left", x: stick.xAxis.value, y: stick.yAxis.value)
            {
                feedAxis(controllerID: controllerID, element: sample.element, value: sample.value)
            }
        }
        if let stick = profile.dpads[GCInputRightThumbstick] {
            for sample in ControllerStickMapper.halfAxisSamples(
                stick: "right", x: stick.xAxis.value, y: stick.yAxis.value)
            {
                feedAxis(controllerID: controllerID, element: sample.element, value: sample.value)
            }
        }
    }

    /// A poll task can still be queued on the main actor when a
    /// controller detaches. This guard keeps such a late poll from
    /// writing state for a removed controller back into the reducer,
    /// which would hold its pressed keys down forever.
    private func isAttached(_ controller: GCController?) -> Bool {
        guard let controller else { return false }
        return connectedControllers[ObjectIdentifier(controller)] != nil
    }

    private func feedOptionalPaddles(controllerID: String, gamepad: GCExtendedGamepad) {
        if let xbox = gamepad as? GCXboxGamepad {
            if let paddle = xbox.paddleButton1 {
                feedButton(controllerID: controllerID, element: "paddle1", pressed: paddle.isPressed)
            }
            if let paddle = xbox.paddleButton2 {
                feedButton(controllerID: controllerID, element: "paddle2", pressed: paddle.isPressed)
            }
            if let paddle = xbox.paddleButton3 {
                feedButton(controllerID: controllerID, element: "paddle3", pressed: paddle.isPressed)
            }
            if let paddle = xbox.paddleButton4 {
                feedButton(controllerID: controllerID, element: "paddle4", pressed: paddle.isPressed)
            }
        } else if let dualSense = gamepad as? GCDualSenseGamepad {
            feedButton(
                controllerID: controllerID,
                element: "touchpad",
                pressed: dualSense.touchpadButton.isPressed
            )
        }
    }

    private func feedButton(controllerID: String, element: String, pressed: Bool) {
        feedAxis(controllerID: controllerID, element: element, value: pressed ? 1 : 0, isAxis: false)
    }

    private func feedButton(controllerID: String, element: String, value: Float) {
        feedAxis(controllerID: controllerID, element: element, value: value, isAxis: true)
    }

    private func feedAxis(
        controllerID: String,
        element: String,
        value: Float,
        isAxis: Bool = true
    ) {
        let edges = reducer.apply(
            controllerID: controllerID,
            element: element,
            value: value,
            isAxis: isAxis
        )
        dispatch(edges: edges)
    }

    private func dispatch(edges: [ControllerStateReducer.Edge]) {
        guard sessionActive else { return }
        for edge in edges {
            if edge.pressed {
                elementActivityHandler?(edge.element)
            }
            if suppressInjection { continue }
            if edge.pressed {
                guard let target = resolvedMap[edge.element] else { continue }
                switch target {
                case .key(let scancode):
                    elementPressScancode[edge.element] = scancode
                    EngineSessionCoordinator.shared.holdKey(
                        scancode: scancode, by: .controller(edge.element))
                case .action(let name):
                    elementPressAction[edge.element] = name
                    actionHandler?(name, true)
                case .unbound:
                    break
                }
            } else {
                if let action = elementPressAction.removeValue(forKey: edge.element) {
                    actionHandler?(action, false)
                    continue
                }
                guard let scancode = elementPressScancode.removeValue(forKey: edge.element) else {
                    continue
                }
                EngineSessionCoordinator.shared.releaseKey(
                    scancode: scancode, by: .controller(edge.element))
            }
        }
    }

    /// Drops everything this path holds. Suppression and stop()
    /// swallow the physical release edges, and a held fast-forward
    /// with no release would leave the engine sped up.
    private func releaseAllHeldInputs() {
        EngineSessionCoordinator.shared.releaseKeys(from: .controller)
        elementPressScancode.removeAll()

        for action in elementPressAction.values {
            actionHandler?(action, false)
        }
        elementPressAction.removeAll()
    }
}

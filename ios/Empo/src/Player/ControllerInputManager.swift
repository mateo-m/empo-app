import Foundation
import GameController
import GameProbe
import UIKit

/// Host-side physical controller input (SPEC section 10.2). Maps GCController
/// elements to keyboard scancodes via the merged four-layer map (section 9).
@MainActor
final class ControllerInputManager {
    /// Dispatches action targets: (action id, pressed). Wired to
    /// `PlayerActionRegistry.handle`. Hold actions rely on the
    /// release edge. See `releaseAllHeldKeys` for the paths where
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

    /// True while at least one controller is attached.
    var hasConnectedController: Bool {
        !connectedControllers.isEmpty
    }

    /// Scancodes a connected controller can press through the merged
    /// element map. The keyboard accessory bar hides these keys.
    var boundKeyScancodes: Set<Int32> {
        Set(
            resolvedMap.values.compactMap { target in
                if case .key(let scancode) = target { return scancode }
                return nil
            })
    }

    /// SDL element names for optional hardware (paddles, touchpad) that
    /// at least one currently connected controller exposes.
    var exposedOptionalElements: Set<String> {
        var exposed = Set<String>()
        for controller in connectedControllers.values {
            for entry in Self.optionalButtons(of: controller.physicalInputProfile) {
                exposed.insert(entry.element)
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
    private var connectedControllers: [String: GCController] = [:]
    private var heldStickDirections: [String: Set<ControllerStickMapper.Direction>] = [:]

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    /// Atomically swap the merged map. Keys held mid-press keep their
    /// press-time scancode until release (SPEC section 10.2 / ticket 004).
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

        // Element callbacks stop while the app is inactive unless
        // `GCController.shouldMonitorBackgroundEvents` is on. A release
        // in that window never arrives, so the key stays pressed until
        // this re-read.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollAllControllers()
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
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        connectObserver = nil
        disconnectObserver = nil
        activeObserver = nil

        for controller in connectedControllers.values {
            clearHandlers(on: controller)
        }
        connectedControllers.removeAll()
        controllersWithLoggedInput.removeAll()
        heldStickDirections.removeAll()
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
            id=\(Self.controllerID(controller)) \
            profile=\(type(of: profile)) \
            extended=\(controller.extendedGamepad != nil) \
            micro=\(controller.microGamepad != nil) \
            mappable=\(Self.isMappable(controller)) \
            elements=[\(elements)]
            """
        )
    }

    /// One line per controller per session, on its first edge. With
    /// the "connected" line it tells apart a pad whose handlers never
    /// fire from a pad whose elements have no binding.
    private var controllersWithLoggedInput: Set<String> = []

    private func logFirstInput(controllerID: String, element: String) {
        guard let deviceLogHandler,
            controllersWithLoggedInput.insert(controllerID).inserted
        else { return }
        deviceLogHandler("controller input: id=\(controllerID) first element=\(element)")
    }

    private static func controllerID(_ controller: GCController) -> String {
        String(UInt(bitPattern: ObjectIdentifier(controller)))
    }

    private func attach(_ controller: GCController) {
        guard sessionActive else { return }
        #if DEBUG
        guard UITestVirtualController.admits(controller) else { return }
        #endif
        logDevice(controller)
        guard Self.isMappable(controller) else { return }
        let id = Self.controllerID(controller)
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

    private func detach(_ controller: GCController) {
        let id = Self.controllerID(controller)
        guard connectedControllers[id] != nil else { return }
        let hadExtendedController = hasExtendedController
        connectedControllers.removeValue(forKey: id)

        clearHandlers(on: controller)
        heldStickDirections = heldStickDirections.filter { !$0.key.hasPrefix(id + ":") }
        let edges = reducer.removeController(id)
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

    /// The handlers sit on the elements, not on the profile. The
    /// typed profile handlers (`GCExtendedGamepad.valueChangedHandler`
    /// and `GCPhysicalInputProfile.valueDidChangeHandler`) never fire
    /// for a snapshot controller, and an 8BitDo FlipPad that reaches
    /// iOS as a `GCMicroGamepad` with 18 elements gave Empo no input
    /// through them, while Delta read the same pad with element
    /// handlers (issue #140).
    ///
    /// Each handler feeds the value it received. The framework queues
    /// handlers on `handlerQueue` asynchronously, so a handler that
    /// re-reads the element sees the latest value, and a press and
    /// its release queued in one turn collapse into no edge.
    private func installHandler(on controller: GCController) {
        let controllerID = Self.controllerID(controller)
        clearHandlers(on: controller)
        controller.handlerQueue = .main
        let profile = controller.physicalInputProfile

        for entry in Self.digitalButtons(of: profile) {
            entry.button.pressedChangedHandler = { [weak self] _, _, pressed in
                Self.onMain {
                    self?.feedButton(controllerID: controllerID, element: entry.element, pressed: pressed)
                }
            }
        }
        for entry in Self.triggers(of: profile) {
            entry.button.valueChangedHandler = { [weak self] _, value, _ in
                Self.onMain {
                    self?.feedButton(controllerID: controllerID, element: entry.element, value: value)
                }
            }
        }
        for entry in Self.sticks(of: profile) {
            entry.dpad.valueChangedHandler = { [weak self] _, x, y in
                Self.onMain {
                    self?.feedStick(controllerID: controllerID, stick: entry.element, x: x, y: y)
                }
            }
        }
        pollProfile(controllerID: controllerID, controller: controller)
    }

    /// `handlerQueue` is the main queue for every pad this manager
    /// owns, so the hop is for a queue that other code moved.
    private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    private func clearHandlers(on controller: GCController) {
        let profile = controller.physicalInputProfile
        for entry in Self.digitalButtons(of: profile) {
            entry.button.pressedChangedHandler = nil
        }
        for entry in Self.triggers(of: profile) {
            entry.button.valueChangedHandler = nil
        }
        for entry in Self.sticks(of: profile) {
            entry.dpad.valueChangedHandler = nil
        }
    }

    /// Rejects devices with only vendor-named elements the mapper
    /// cannot use.
    private static func isMappable(_ controller: GCController) -> Bool {
        let profile = controller.physicalInputProfile
        return !digitalButtons(of: profile).isEmpty || !triggers(of: profile).isEmpty
            || !sticks(of: profile).isEmpty
    }

    private typealias NamedButton = (element: String, button: GCControllerButtonInput)

    /// The GCInput constants are the same strings on every profile, so
    /// the reducer, the resolved map, and the remap UI see one
    /// vocabulary for all controller classes.
    private static let profileButtonElements: [(name: String, element: String)] = [
        (GCInputButtonA, "a"), (GCInputButtonB, "b"),
        (GCInputButtonX, "x"), (GCInputButtonY, "y"),
        (GCInputLeftShoulder, "leftshoulder"), (GCInputRightShoulder, "rightshoulder"),
        (GCInputButtonMenu, "start"), (GCInputButtonOptions, "back"),
        (GCInputButtonHome, "guide"),
        (GCInputLeftThumbstickButton, "leftstick"), (GCInputRightThumbstickButton, "rightstick"),
    ]

    private static func digitalButtons(of profile: GCPhysicalInputProfile) -> [NamedButton] {
        var buttons: [NamedButton] = profileButtonElements.compactMap { entry in
            profile.buttons[entry.name].map { (entry.element, $0) }
        }
        if let dpad = profile.dpads[GCInputDirectionPad] {
            buttons += [
                ("dpup", dpad.up), ("dpdown", dpad.down), ("dpleft", dpad.left), ("dpright", dpad.right),
            ]
        }
        return buttons + optionalButtons(of: profile)
    }

    /// The typed accessors come first. The header does not promise
    /// that a DualSense keys its touchpad button under the DualShock
    /// name.
    private static func optionalButtons(of profile: GCPhysicalInputProfile) -> [NamedButton] {
        if let xbox = profile as? GCXboxGamepad {
            return [
                ("paddle1", xbox.paddleButton1), ("paddle2", xbox.paddleButton2),
                ("paddle3", xbox.paddleButton3), ("paddle4", xbox.paddleButton4),
            ].compactMap { element, button in button.map { (element, $0) } }
        }
        if let dualSense = profile as? GCDualSenseGamepad {
            return [("touchpad", dualSense.touchpadButton)]
        }
        let named: [(name: String, element: String)] = [
            (GCInputXboxPaddleOne, "paddle1"), (GCInputXboxPaddleTwo, "paddle2"),
            (GCInputXboxPaddleThree, "paddle3"), (GCInputXboxPaddleFour, "paddle4"),
            (GCInputDualShockTouchpadButton, "touchpad"),
        ]
        return named.compactMap { entry in profile.buttons[entry.name].map { (entry.element, $0) } }
    }

    private static func triggers(of profile: GCPhysicalInputProfile) -> [NamedButton] {
        [(GCInputLeftTrigger, "lefttrigger"), (GCInputRightTrigger, "righttrigger")]
            .compactMap { name, element in profile.buttons[name].map { (element, $0) } }
    }

    private static func sticks(
        of profile: GCPhysicalInputProfile
    ) -> [(element: String, dpad: GCControllerDirectionPad)] {
        [(GCInputLeftThumbstick, "left"), (GCInputRightThumbstick, "right")]
            .compactMap { name, element in profile.dpads[name].map { (element, $0) } }
    }

    /// Reads the state a controller holds right now. Only the elements
    /// the hardware exposes get fed. Absent names stay untouched so
    /// the reducer never sees false releases.
    private func pollProfile(controllerID: String, controller: GCController) {
        let profile = controller.physicalInputProfile
        for entry in Self.digitalButtons(of: profile) {
            feedButton(controllerID: controllerID, element: entry.element, pressed: entry.button.isPressed)
        }
        for entry in Self.triggers(of: profile) {
            feedButton(controllerID: controllerID, element: entry.element, value: entry.button.value)
        }
        for entry in Self.sticks(of: profile) {
            feedStick(
                controllerID: controllerID, stick: entry.element,
                x: entry.dpad.xAxis.value, y: entry.dpad.yAxis.value)
        }
    }

    private func pollAllControllers() {
        for (controllerID, controller) in connectedControllers {
            pollProfile(controllerID: controllerID, controller: controller)
        }
    }

    private func feedStick(controllerID: String, stick: String, x: Float, y: Float) {
        let key = "\(controllerID):\(stick)"
        let active = ControllerStickMapper.directions(x: x, y: y, held: heldStickDirections[key] ?? [])
        heldStickDirections[key] = active
        for sample in ControllerStickMapper.halfAxisSamples(stick: stick, x: x, y: y, active: active) {
            feedAxis(controllerID: controllerID, element: sample.element, value: sample.value)
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
        // A handler queued before its controller detached would write
        // pressed keys back into the reducer and hold them down forever.
        guard sessionActive, connectedControllers[controllerID] != nil else { return }
        let edges = reducer.apply(
            controllerID: controllerID,
            element: element,
            value: value,
            isAxis: isAxis
        )
        if let first = edges.first {
            logFirstInput(controllerID: controllerID, element: first.element)
        }
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

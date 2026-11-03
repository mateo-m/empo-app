// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Host-side physical controller input (SPEC section 10.2). Maps
/// controller elements to keyboard scancodes via the merged four-layer
/// map (section 9). A reader turns each pad's input into SDL element
/// names: Apple's GameController on iOS, SDL on the Mac.
@MainActor
final class ControllerInputManager {
    /// Dispatches action targets: (action id, pressed). Wired to
    /// `PlayerActionRegistry.handle`. Hold actions rely on the
    /// release edge. See `releaseAllHeldKeys` for the paths where
    /// release edges cannot arrive.
    /// Returns false when the action refuses the press.
    var actionHandler: ((String, Bool) -> Bool)?

    /// Runs on physical element press edges (listen mode for the remap UI).
    var elementActivityHandler: ((String) -> Void)?

    var connectionHandler: (() -> Void)?

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
        connectedControllers.values.reduce(into: []) { $0.formUnion($1.optionalElements) }
    }

    private struct ConnectedPad {
        let isExtended: Bool
        let optionalElements: Set<String>
    }

    #if os(macOS)
    private typealias Reader = SDLControllerReader
    #else
    private typealias Reader = GameControllerReader
    #endif

    private var sessionActive = false
    private var reducer = ControllerStateReducer()
    private var resolvedMap = BindingResolver.resolveRuntime().elements
    private var elementPressScancode: [String: Int32] = [:]
    // element -> action id held by that element, mirroring
    // elementPressScancode so hold actions get their release edge.
    private var elementPressAction: [String: String] = [:]
    private var connectedControllers: [String: ConnectedPad] = [:]
    private var heldStickDirections: [String: Set<ControllerStickMapper.Direction>] = [:]
    private lazy var reader = Reader(manager: self)

    private let keys: HeldKeys<KeyHolder>

    private var activeObserver: NSObjectProtocol?

    init(keys: HeldKeys<KeyHolder>) {
        self.keys = keys
    }

    #if os(iOS)
    convenience init() {
        self.init(keys: EngineSessionCoordinator.shared.heldKeys)
    }
    #endif

    /// Atomically swap the merged map. Keys held mid-press keep their
    /// press-time scancode until release (SPEC section 10.2 / ticket 004).
    func updateResolvedMap(_ map: [String: ResolvedTarget]) {
        resolvedMap = map
    }

    func start() {
        stop()
        sessionActive = true
        hasHadControllerThisSession = false

        // No pad input reaches this manager while the app is inactive.
        // A release in that window never arrives, so the key stays
        // pressed until this re-read.
        #if canImport(UIKit)
        let didBecomeActive = UIApplication.didBecomeActiveNotification
        #else
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        #endif
        activeObserver = NotificationCenter.default.addObserver(
            forName: didBecomeActive,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reader.pollAll()
            }
        }

        reader.start()
    }

    func stop() {
        sessionActive = false
        releaseAllHeldInputs()

        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        activeObserver = nil

        reader.stop()
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
    /// apart a pad the system never exposed, a pad with element names
    /// Empo does not know, and a pad that works but is bound elsewhere.
    var deviceLogHandler: ((String) -> Void)?

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

    // MARK: - Reader events

    /// The reader calls this before it feeds the pad's first input.
    func padConnected(_ controllerID: String, isExtended: Bool, optionalElements: Set<String>) {
        guard sessionActive, connectedControllers[controllerID] == nil else { return }
        let priorCount = connectedControllers.count
        connectedControllers[controllerID] = ConnectedPad(
            isExtended: isExtended, optionalElements: optionalElements)
        hasHadControllerThisSession = true

        overlay?.update {
            $0.setExtendedController(hasExtendedController, isFirstController: priorCount == 0)
        }
        connectionHandler?()
    }

    func padDisconnected(_ controllerID: String) {
        guard connectedControllers[controllerID] != nil else { return }
        let hadExtendedController = hasExtendedController
        connectedControllers.removeValue(forKey: controllerID)

        heldStickDirections = heldStickDirections.filter { !$0.key.hasPrefix(controllerID + ":") }
        let edges = reducer.removeController(controllerID)
        dispatch(edges: edges)

        if connectedControllers.isEmpty {
            overlay?.update { $0.noteAllControllersDisconnected() }
        } else if hadExtendedController != hasExtendedController {
            overlay?.update { $0.setExtendedController(hasExtendedController) }
        }
        connectionHandler?()
    }

    private var hasExtendedController: Bool {
        connectedControllers.values.contains { $0.isExtended }
    }

    /// `x` grows to the right and `y` grows up.
    func feedStick(controllerID: String, stick: String, x: Float, y: Float) {
        let key = "\(controllerID):\(stick)"
        let active = ControllerStickMapper.directions(x: x, y: y, held: heldStickDirections[key] ?? [])
        heldStickDirections[key] = active
        for sample in ControllerStickMapper.halfAxisSamples(stick: stick, x: x, y: y, active: active) {
            feedAxis(controllerID: controllerID, element: sample.element, value: sample.value)
        }
    }

    func feedButton(controllerID: String, element: String, pressed: Bool) {
        feedAxis(controllerID: controllerID, element: element, value: pressed ? 1 : 0, isAxis: false)
    }

    func feedButton(controllerID: String, element: String, value: Float) {
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
                    keys.hold(scancode, by: .controller(edge.element))
                case .action(let name):
                    if actionHandler?(name, true) == true {
                        elementPressAction[edge.element] = name
                    }
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
                keys.release(scancode, by: .controller(edge.element))
            }
        }
    }

    /// Drops everything this path holds. Suppression and stop()
    /// swallow the physical release edges, and a held fast-forward
    /// with no release would leave the engine sped up.
    func releaseAllHeldInputs() {
        keys.release { $0.source == .controller }
        elementPressScancode.removeAll()

        for action in elementPressAction.values {
            actionHandler?(action, false)
        }
        elementPressAction.removeAll()
    }

    /// Also forgets which elements are down, so the poll when the app
    /// becomes active presses an element that is still held.
    func releaseAndForgetHeldInputs() {
        releaseAllHeldInputs()
        reducer = ControllerStateReducer()
        heldStickDirections.removeAll()
    }
}

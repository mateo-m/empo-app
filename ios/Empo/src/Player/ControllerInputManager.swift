// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
final class ControllerInputManager {
    /// Takes (action id, pressed). Returns false when the action
    /// refuses the press.
    var actionHandler: ((String, Bool) -> Bool)?

    var elementActivityHandler: ((String) -> Void)?

    var connectionHandler: (() -> Void)?

    /// Suppression swallows the release edges of the keys held when it
    /// begins. Release those keys now, or they stay stuck in the engine.
    var suppressInjection = false {
        didSet {
            if suppressInjection, !oldValue {
                releaseAllHeldInputs()
            }
        }
    }

    weak var overlay: OverlayVisibilityController?

    private(set) var hasHadControllerThisSession = false

    var hasConnectedController: Bool {
        !connectedControllers.isEmpty
    }

    var boundKeyScancodes: Set<Int32> {
        Set(
            resolvedMap.values.compactMap { target in
                if case .key(let scancode) = target { return scancode }
                return nil
            })
    }

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
    private var elementPressAction: [String: String] = [:]
    private var connectedControllers: [String: ConnectedPad] = [:]
    private var heldStickDirections: [String: Set<ControlDirection>] = [:]
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

    /// A key that is held now keeps its press-time scancode until release.
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

    var deviceLogHandler: ((String) -> Void)?

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
                    _ = actionHandler?(action, false)
                    continue
                }
                guard let scancode = elementPressScancode.removeValue(forKey: edge.element) else {
                    continue
                }
                keys.release(scancode, by: .controller(edge.element))
            }
        }
    }

    /// Suppression and stop() swallow the physical release edges. A held
    /// fast-forward with no release leaves the engine sped up.
    func releaseAllHeldInputs() {
        keys.release { $0.source == .controller }
        elementPressScancode.removeAll()

        for action in elementPressAction.values {
            _ = actionHandler?(action, false)
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

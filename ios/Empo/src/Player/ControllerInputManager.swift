// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

final class ControllerInputManager: InputManager<String> {
    var elementActivityHandler: ((String) -> Void)?

    var connectionHandler: (() -> Void)?

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

    private var reducer = ControllerStateReducer()
    private var connectedControllers: [String: ConnectedPad] = [:]
    private var heldStickDirections: [String: Set<ControlDirection>] = [:]
    private lazy var reader = Reader(manager: self)

    private var activeObserver: NSObjectProtocol?

    init(keys: HeldKeys<KeyHolder>) {
        super.init(
            keys: keys, source: .controller, holder: KeyHolder.controller,
            resolvedMap: BindingResolver.resolveRuntime().elements)
    }

    #if os(iOS)
    convenience init() {
        self.init(keys: EngineSessionCoordinator.shared.heldKeys)
    }
    #endif

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
    }

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
                if let target = resolvedMap[edge.element] {
                    press(edge.element, as: target)
                }
            } else {
                release(edge.element)
            }
        }
    }

    /// Also forgets which elements are down, so the poll when the app
    /// becomes active presses an element that is still held.
    func releaseAndForgetHeldInputs() {
        releaseAllHeldInputs()
        reducer = ControllerStateReducer()
        heldStickDirections.removeAll()
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe
import Observation
import SwiftUI

/// The engine calls that the player actions make. The iOS app links
/// the engine. Empo Player on the Mac opens it from a core file.
struct PlayerEngine {
    let fastForwardMultiplier: () -> Int
    let setFastForwardMultiplier: (Int) -> Void
    let setCheatsEnabled: (Bool) -> Void
    let tapKey: (_ scancode: Int32, _ holdMilliseconds: Int) -> Void

    /// For a screen that shows the actions while no game runs.
    static var none: PlayerEngine {
        PlayerEngine(
            fastForwardMultiplier: { 1 }, setFastForwardMultiplier: { _ in }, setCheatsEnabled: { _ in },
            tapKey: { _, _ in })
    }
}

/// SwiftUI makes `PlayerView` again on pause and resume, but the
/// multiplier of the engine stays for the process, so this state is not
/// in the view. The fast forward state comes from the engine each time.
@MainActor
@Observable
final class PlayerRuntimeState {
    private(set) var fastForwardActive = false
    private(set) var fastForwardMultiplier: Int?
    private(set) var cheatsAvailable = false

    private var arbiter = FastForwardArbiter()
    private let engine: PlayerEngine

    init(engine: PlayerEngine) {
        self.engine = engine
    }

    var fastForwardAvailable: Bool {
        FastForwardArbiter.usableMultiplier(fastForwardMultiplier) != nil
    }

    func bind(fastForwardMultiplier: Int?, cheatsAvailable: Bool) {
        arbiter = FastForwardArbiter()
        self.cheatsAvailable = cheatsAvailable
        reconcile(fastForwardMultiplier: fastForwardMultiplier)
    }

    /// The arbiter refuses to adopt the bridge state mid-hold, so an
    /// in-progress hold cannot convert into a latch.
    func reconcile(fastForwardMultiplier: Int?) {
        self.fastForwardMultiplier = fastForwardMultiplier
        let outcome = arbiter.reconcile(
            configuredMultiplier: fastForwardMultiplier,
            bridgeMultiplier: bridgeMultiplier()
        )
        apply(outcome.write)
        refreshFastForwardActive()
    }

    // MARK: - Fast forward

    func fastForwardHoldChanged(pressed: Bool) {
        let write =
            pressed
            ? arbiter.holdPressed(
                configuredMultiplier: fastForwardMultiplier,
                bridgeMultiplier: bridgeMultiplier())
            : arbiter.holdReleased(
                configuredMultiplier: fastForwardMultiplier,
                bridgeMultiplier: bridgeMultiplier())
        apply(write)
        refreshFastForwardActive()
    }

    func fastForwardToggled() {
        let write = arbiter.toggled(
            configuredMultiplier: fastForwardMultiplier,
            bridgeMultiplier: bridgeMultiplier()
        )
        apply(write)
        refreshFastForwardActive()
    }

    /// Off clears the latch also while a hold keeps the speed up.
    func setFastForward(active: Bool) {
        guard active != fastForwardActive else { return }
        if active {
            fastForwardToggled()
        } else {
            apply(arbiter.latchCleared(bridgeMultiplier: bridgeMultiplier()))
            refreshFastForwardActive()
        }
    }

    // MARK: - Bridge

    private func refreshFastForwardActive() {
        fastForwardActive = bridgeMultiplier() > 1
    }

    private func bridgeMultiplier() -> Int {
        engine.fastForwardMultiplier()
    }

    private func apply(_ write: Int?) {
        guard let write else { return }
        engine.setFastForwardMultiplier(write)
    }
}

@MainActor
final class PlayerActionRegistry {
    let runtime: PlayerRuntimeState

    private let engine: PlayerEngine

    init(engine: PlayerEngine) {
        self.engine = engine
        runtime = PlayerRuntimeState(engine: engine)
    }

    /// Empo Player on the Mac has no touch controls.
    static let actionIDs: Set<String> = {
        #if os(macOS)
        EmpoActionCatalog.allIDs.subtracting([EmpoActionCatalog.toggleTouchControls])
        #else
        EmpoActionCatalog.allIDs
        #endif
    }()
    static let actions = EmpoActionCatalog.all.filter { actionIDs.contains($0.id) }

    var pauseMenu: () -> Void = {}
    var toggleTouchControls: () -> Void = {}
    var log: (String) -> Void = { _ in }

    private struct ActionBehavior {
        var isAvailable: () -> Bool = { true }
        var isActive: () -> Bool = { false }
        var handle: (Bool) -> Void
    }

    private static func pressOnly(_ body: @escaping () -> Void) -> (Bool) -> Void {
        { pressed in
            guard pressed else { return }
            body()
        }
    }

    /// Lazy: `pauseMenu` and `toggleTouchControls` capture self, so the
    /// closures read the wiring the player scene sets after init.
    private lazy var behaviors: [String: ActionBehavior] = [
        EmpoActionCatalog.fastForwardHold: ActionBehavior(
            isAvailable: { [runtime] in runtime.fastForwardAvailable },
            handle: { [runtime] pressed in
                runtime.fastForwardHoldChanged(pressed: pressed)
            }),
        EmpoActionCatalog.fastForwardToggle: ActionBehavior(
            isAvailable: { [runtime] in runtime.fastForwardAvailable },
            isActive: { [runtime] in runtime.fastForwardActive },
            handle: Self.pressOnly { [runtime] in runtime.fastForwardToggled() }),
        EmpoActionCatalog.pauseMenu: ActionBehavior(
            handle: Self.pressOnly { [weak self] in self?.pauseMenu() }),
        EmpoActionCatalog.toggleCheats: ActionBehavior(
            isAvailable: { [runtime] in runtime.cheatsAvailable },
            handle: Self.pressOnly { [engine] in
                // The cheat scripts of the engine open their menu on HOME
                // while the bridge flag is on.
                engine.setCheatsEnabled(true)
                engine.tapKey(
                    Int32(GAMECORE_SCANCODE_HOME), HeldKeys<KeyHolder>.tapHoldMilliseconds)
            }),
        EmpoActionCatalog.toggleTouchControls: ActionBehavior(
            handle: Self.pressOnly { [weak self] in self?.toggleTouchControls() }),
    ]

    /// Whether the action does anything for the current game. An
    /// unavailable action's touch button hides during play. A
    /// controller binding to one stays inert.
    func isAvailable(_ actionID: String) -> Bool {
        Self.actionIDs.contains(actionID) && behaviors[actionID]?.isAvailable() ?? false
    }

    /// A latched toggle shows its engaged state on the button face.
    func isToggleActive(_ action: EmpoAction) -> Bool {
        guard action.kind == .toggle else { return false }
        return behaviors[action.id]?.isActive() ?? false
    }

    /// `pressed` is true on press edges. Hold actions also receive
    /// the release edge. Toggle and instant actions ignore it.
    /// Returns false when the action refuses a press. The caller must
    /// then not send its release: the arbiter counts holds, so that
    /// release would end the hold of another button.
    @discardableResult
    func handle(_ actionID: String, pressed: Bool) -> Bool {
        guard EmpoActionCatalog.action(id: actionID) != nil else {
            if pressed {
                log("Controls: unknown action \(actionID) does nothing")
            }
            return false
        }
        // Availability gates press edges only. A release must always
        // reach the arbiter, or a hold whose availability flipped
        // mid-press would stick.
        if pressed, !isAvailable(actionID) {
            log("Controls: action \(actionID) is unavailable for this game")
            return false
        }

        behaviors[actionID]?.handle(pressed)
        return true
    }
}

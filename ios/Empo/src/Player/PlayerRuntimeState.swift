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

/// Session runtime state the player actions act on. SwiftUI recycles
/// `PlayerView` on pause/resume while the engine's multiplier is
/// process-static, so this does not live in the view.
/// The bridge is the source of truth. This model re-derives from it
/// at every safe point and on every activation, never from a cached
/// flag.
@MainActor
@Observable
final class PlayerRuntimeState {
    /// True while the engine multiplier is above 1. Drives the More
    /// sheet toggle and the active state of fast-forward buttons.
    private(set) var fastForwardActive = false
    /// Per-game multiplier from Game Settings. nil = fast forward is
    /// off for this game and the fast-forward actions are unavailable.
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

    /// Binds the model to a new session and adopts bridge state. A
    /// nil multiplier turns fast forward off for the game.
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
        fastForwardActive = outcome.active
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

    /// Binding adapter for the More sheet's Toggle row. Unlike the
    /// stateless toggle button, the Toggle carries an explicit target
    /// value: OFF must clear the latch even while a hold keeps the
    /// speed up, never arm it.
    func setFastForward(active: Bool) {
        guard active != fastForwardActive else { return }
        if active {
            fastForwardToggled()
        } else {
            apply(arbiter.latchCleared(bridgeMultiplier: bridgeMultiplier()))
            refreshFastForwardActive()
        }
    }

    /// Fires when every hold must drop at once (input suppression,
    /// session stop, scene teardown).
    func releaseAllFastForwardHolds() {
        let write = arbiter.releaseAllHolds(
            configuredMultiplier: fastForwardMultiplier,
            bridgeMultiplier: bridgeMultiplier()
        )
        apply(write)
        refreshFastForwardActive()
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

/// One dispatch point for every Empo action, shared by the touch and
/// controller input paths. Replaces the hardcoded action switch in
/// `ControllerInputManager`.
@MainActor
final class PlayerActionRegistry {
    let runtime: PlayerRuntimeState

    private let engine: PlayerEngine

    init(engine: PlayerEngine) {
        self.engine = engine
        runtime = PlayerRuntimeState(engine: engine)
    }

    /// The actions this app runs. Empo Player on the Mac has no touch
    /// controls.
    static let actionIDs: Set<String> = {
        #if os(macOS)
        [
            EmpoActionCatalog.fastForwardHold, EmpoActionCatalog.fastForwardToggle,
            EmpoActionCatalog.pauseMenu,
            EmpoActionCatalog.toggleCheats,
        ]
        #else
        EmpoActionCatalog.allIDs
        #endif
    }()
    static let actions = EmpoActionCatalog.all.filter { actionIDs.contains($0.id) }

    /// Wired by the player scene on appear.
    var pauseMenu: () -> Void = {}
    var toggleTouchControls: () -> Void = {}
    var log: (String) -> Void = { _ in }

    /// One behavior record per action: availability, latched state,
    /// and the edge handler. Availability, dispatch, and the button
    /// face all read THIS table, so a new action registers in one
    /// place. No kind-vs-id split across files.
    private struct ActionBehavior {
        var isAvailable: () -> Bool = { true }
        var isActive: () -> Bool = { false }
        /// Receives both edges. Toggle and instant behaviors wrap
        /// themselves in `pressOnly`.
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
                // The engine's cheat scripts open their menu on HOME while
                // the bridge flag is on. The KEYUP must land at least one
                // RGSS tick after the KEYDOWN or Input.trigger?(HOME) never
                // sees the edge.
                engine.setCheatsEnabled(true)
                engine.tapKey(Int32(GAMECORE_SCANCODE_HOME), 100)
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

    /// Drops every held action at once. `ControllerInputManager`
    /// calls this from its release-all path so a held fast-forward
    /// cannot stick when suppression starts or the session stops.
    func releaseAllHolds() {
        runtime.releaseAllFastForwardHolds()
    }
}

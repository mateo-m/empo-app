import Foundation
import GameProbe
import SwiftUI

/// Session runtime state the player actions act on: fast forward and
/// cheats. It used to live as `@State` in `PlayerView`, but SwiftUI
/// recycles that view on pause/resume while the engine's multiplier
/// and cheat flag are process-static. The bridge is the source of
/// truth; this model re-derives from it at every safe point and on
/// every activation, never from a cached flag.
@MainActor
@Observable
final class PlayerRuntimeState {
  /// True while the engine multiplier is above 1. Drives the More
  /// sheet toggle and the active state of fast-forward buttons.
  private(set) var fastForwardActive = false
  /// Per-game multiplier from Game Settings. nil = fast forward is
  /// off for this game and the fast-forward actions are unavailable.
  private(set) var fastForwardMultiplier: Int?
  private(set) var cheatsEnabled = false

  private var arbiter = FastForwardArbiter()
  private var container: GameContainer?

  var fastForwardAvailable: Bool {
    (fastForwardMultiplier ?? 0) >= 2
  }

  /// Binds the model to the running game and adopts bridge state.
  func bind(container: GameContainer?) {
    self.container = container
    arbiter = FastForwardArbiter()
    reconcile()
  }

  /// Re-reads the per-game multiplier and adopts the bridge state.
  /// Safe points only: session start, resume, More-sheet open. The
  /// arbiter refuses to adopt mid-hold, so an in-progress hold
  /// cannot convert into a latch.
  func reconcile() {
    reloadMultiplier()
    let outcome = arbiter.reconcile(
      configuredMultiplier: fastForwardMultiplier,
      bridgeMultiplier: bridgeMultiplier()
    )
    apply(outcome.write)
    fastForwardActive = outcome.active
    cheatsEnabled = mkxp_getCheatsEnabled()
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

  // MARK: - Cheats

  /// Toggle the JoiPlay-derived cheat menu. The first activation
  /// arms $CHEATS and injects a HOME keypress so the in-game
  /// Scene_Cheat hook fires immediately. The next disarms $CHEATS.
  /// The Ruby-side poller the engine installs keeps $CHEATS in sync
  /// with the bridge flag each Input.update.
  func toggleCheats() {
    let next = !mkxp_getCheatsEnabled()
    mkxp_setCheatsEnabled(next)
    cheatsEnabled = next
    if next {
      // The KEYUP must land at least one RGSS tick after the
      // KEYDOWN or Input.trigger?(HOME) never sees the edge.
      EngineSessionCoordinator.shared.injectKeyTap(
        scancode: Int32(MKXP_SCANCODE_HOME), holdMilliseconds: 100)
    }
  }

  // MARK: - Bridge

  private func reloadMultiplier() {
    guard let container else {
      fastForwardMultiplier = nil
      return
    }
    fastForwardMultiplier = GameSettings.load(from: container.empoStateURL).speedMultiplier
  }

  private func refreshFastForwardActive() {
    fastForwardActive = bridgeMultiplier() > 1
  }

  private func bridgeMultiplier() -> Int {
    Int(mkxp_getFastForwardMultiplier())
  }

  private func apply(_ write: Int?) {
    guard let write else { return }
    mkxp_setFastForwardMultiplier(Int32(write))
  }
}

/// One dispatch point for every Empo action, shared by the touch and
/// controller input paths. Replaces the hardcoded action switch in
/// `ControllerInputManager`.
@MainActor
final class PlayerActionRegistry {
  let runtime = PlayerRuntimeState()

  /// Wired by the player scene on appear.
  var pauseMenu: () -> Void = {}
  var toggleTouchControls: () -> Void = {}
  var log: (String) -> Void = { _ in }

  /// Whether the action does anything for the current game. An
  /// unavailable action's touch button hides during play; a
  /// controller binding to one stays inert.
  func isAvailable(_ actionID: String) -> Bool {
    switch actionID {
    case EmpoActionCatalog.fastForwardHold, EmpoActionCatalog.fastForwardToggle:
      return runtime.fastForwardAvailable
    default:
      return EmpoActionCatalog.allIDs.contains(actionID)
    }
  }

  /// `pressed` is true on press edges. Hold actions also receive
  /// the release edge; toggle and instant actions ignore it.
  func handle(_ actionID: String, pressed: Bool) {
    guard let action = EmpoActionCatalog.action(id: actionID) else {
      if pressed {
        log("Controls: unknown action \(actionID) does nothing")
      }
      return
    }
    // Availability gates press edges only. A release must always
    // reach the arbiter, or a hold whose availability flipped
    // mid-press would stick (the arbiter self-guards on
    // holdCount, so spurious releases are safe).
    if pressed, !isAvailable(actionID) {
      log("Controls: action \(actionID) is unavailable for this game")
      return
    }

    switch action.kind {
    case .hold:
      runtime.fastForwardHoldChanged(pressed: pressed)
    case .toggle, .instant:
      guard pressed else { return }
      switch actionID {
      case EmpoActionCatalog.fastForwardToggle:
        runtime.fastForwardToggled()
      case EmpoActionCatalog.pauseMenu:
        pauseMenu()
      case EmpoActionCatalog.toggleCheats:
        runtime.toggleCheats()
      case EmpoActionCatalog.toggleTouchControls:
        toggleTouchControls()
      default:
        break
      }
    }
  }

  /// Drops every held action at once. `ControllerInputManager`
  /// calls this from its release-all path so a held fast-forward
  /// cannot stick when suppression starts or the session stops.
  func releaseAllHolds() {
    runtime.releaseAllFastForwardHolds()
  }
}

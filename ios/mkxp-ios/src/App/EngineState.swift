import Foundation
import UIKit
import Observation

/// Engine-level state for the player/viewport.
/// Owns properties that only matter while a game is running:
/// viewport rect, pause snapshots, quit confirmation, and
/// pause/resume lifecycle methods.
@MainActor @Observable
class EngineState {
    static let shared = EngineState()

    /// The current game viewport rect, updated by the engine on every resize.
    var gameRect: CGRect = .zero

    /// Whether the quit confirmation alert is showing.
    var showQuitConfirm = false

    /// Snapshot of the game viewport captured when pausing.
    /// The SDL window can't participate in SwiftUI transitions, so this
    /// frozen frame acts as a static double during the hero zoom animation.
    /// See docs/pause-resume.md.
    var pauseSnapshot: UIImage?

    /// Set to true when the engine swaps its first frame after resume.
    /// PlayerView watches this to know when the live SDL surface is
    /// visible and it's safe to fade out the snapshot overlay.
    var snapshotCanFade = false

    /// Whether the current pause was triggered by app backgrounding
    /// (silent — no UI transition to library).
    var isBackgroundPause = false

    private init() {}

    // MARK: - Actions

    /// User tapped the quit button — show confirmation.
    func requestQuit() {
        guard UserDefaults.standard.bool(forKey: ExperimentalFeature.gameQuit.rawValue) else { return }
        showQuitConfirm = true
    }

    /// User confirmed quit — immediately show library, then tear down engine.
    func confirmQuit() {
        showQuitConfirm = false
        AppState.shared.returnToLibrary()
    }

    /// Request the engine to pause and return to library.
    /// Called from the toolbar pause button.
    func requestPause() {
        guard AppState.shared.phase == .playing else { return }
        isBackgroundPause = false
        mkxp_requestPause()
    }

    /// Pause the engine silently without leaving the player.
    /// Called when the app moves to the background; auto-resumes on foreground.
    func requestBackgroundPause() {
        guard AppState.shared.phase == .playing else { return }
        isBackgroundPause = true
        mkxp_requestPause()
    }

    /// Resume the engine if it was paused by a background transition.
    /// Called when the app returns to the foreground.
    func resumeFromBackground() {
        guard AppState.shared.phase == .playing, mkxp_isPaused() else { return }
        mkxp_requestResume()
    }

    /// Clears all engine state. Called by AppState during teardown.
    func reset() {
        pauseSnapshot = nil
        snapshotCanFade = false
    }
}

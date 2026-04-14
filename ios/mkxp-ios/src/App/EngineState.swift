import Foundation
import UIKit
import Observation

/// Engine-level state owned by the player/viewport.
@MainActor @Observable
class EngineState {
    static let shared = EngineState()

    var gameRect: CGRect = .zero
    var showQuitConfirm = false

    /// The SDL window can't participate in SwiftUI transitions, so this
    /// frozen frame acts as a static double during the hero zoom animation.
    var pauseSnapshot: UIImage?

    /// True once the engine swaps its first frame after resume — signals
    /// PlayerView that it's safe to fade out the snapshot overlay.
    var snapshotCanFade = false

    /// Whether the current pause was triggered by app backgrounding
    /// (silent — no UI transition to library).
    var isBackgroundPause = false

    private init() {}

    // MARK: - Actions

    func requestQuit() {
        guard UserDefaults.standard.bool(forKey: ExperimentalFeature.gameQuit.rawValue) else { return }
        showQuitConfirm = true
    }

    func confirmQuit() {
        showQuitConfirm = false
        AppState.shared.returnToLibrary()
    }

    func requestPause() {
        guard AppState.shared.phase == .playing else { return }
        isBackgroundPause = false
        mkxp_requestPause()
    }

    func requestBackgroundPause() {
        guard AppState.shared.phase == .playing else { return }
        isBackgroundPause = true
        mkxp_requestPause()
    }

    func resumeFromBackground() {
        guard AppState.shared.phase == .playing, mkxp_isPaused() else { return }
        mkxp_requestResume()
    }

    func reset() {
        pauseSnapshot = nil
        snapshotCanFade = false
    }
}

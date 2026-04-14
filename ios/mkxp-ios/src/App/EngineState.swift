import Foundation
import UIKit
import Observation

@MainActor @Observable
class EngineState {
    static let shared = EngineState()

    var gameRect: CGRect = .zero

    /// Whether the current pause was triggered by app backgrounding
    /// (silent — no UI transition to library).
    var isBackgroundPause = false

    private init() {}

    // MARK: - Background Lifecycle

    func requestBackgroundPause() {
        guard AppState.shared.phase == .playing else { return }
        isBackgroundPause = true
        mkxp_requestPause()
    }

    func resumeFromBackground() {
        guard AppState.shared.phase == .playing, mkxp_isPaused() else { return }
        mkxp_requestResume()
    }
}

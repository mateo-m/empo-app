import Foundation
import UIKit
import Observation

@MainActor @Observable
class EngineState {
    static let shared = EngineState()

    var gameRect: CGRect = .zero

    /// Whether the current pause was triggered by app backgrounding
    /// (silent; no UI transition to library).
    var isBackgroundPause = false

    private init() {}


    /// Caller must guard `phase == .playing` before calling.
    func requestBackgroundPause() {
        isBackgroundPause = true
        mkxp_requestPause()
    }

    /// Caller must guard `phase == .playing` before calling.
    func resumeFromBackground() {
        guard mkxp_isPaused() else { return }
        mkxp_requestResume()
    }
}

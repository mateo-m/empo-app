import Foundation
import Observation
import UIKit

@MainActor @Observable
class EngineState {
    static let shared = EngineState()

    var gameRect: CGRect = .zero

    /// True when app backgrounding triggered the current pause
    /// (silent, no UI transition to the library).
    var isBackgroundPause = false

    private init() {}

    /// The caller must guard `phase == .playing` before the call.
    func requestBackgroundPause() {
        isBackgroundPause = true
        gamecore_requestPause()
    }

    /// The caller must guard `phase == .playing` before the call.
    func resumeFromBackground() {
        guard gamecore_isPaused() else { return }
        gamecore_requestResume()
    }
}

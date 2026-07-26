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

    // Background pause/resume talk to the mkxp bridge directly.
    // For a `.view` surface session (rmWeb, dormant) these calls
    // hit an idle engine parked in waitForGamePath and do nothing.
    // TODO(rmweb-activation): route background pause through the
    // active `CoreSession` (WKWebView largely self-suspends, but
    // audio/rAF freezing should go through the session's pause).

    /// The caller must guard `phase == .playing` before the call.
    func requestBackgroundPause() {
        isBackgroundPause = true
        mkxp_requestPause()
    }

    /// The caller must guard `phase == .playing` before the call.
    func resumeFromBackground() {
        guard mkxp_isPaused() else { return }
        mkxp_requestResume()
    }
}

import Foundation
import SwiftUI
import Observation

@MainActor @Observable
final class PauseManager {
    static let shared = PauseManager()

    private(set) var pausedGame: GameEntry?

    /// Frozen frame captured at pause time — used as a static double
    /// during the hero zoom animation (SDL can't participate in SwiftUI transitions).
    var pauseSnapshot: UIImage?

    /// True once the engine swaps its first frame after resume — signals
    /// PlayerView that it's safe to fade out the snapshot overlay.
    var snapshotCanFade = false

    private init() {}


    func requestPause() {
        guard AppSettings.shared.isEnabled(.gamePause),
              AppState.shared.phase == .playing else { return }
        EngineState.shared.isBackgroundPause = false
        mkxp_requestPause()
    }

    /// Called on the main thread from the bridge's paused callback.
    /// Background pauses are ignored here — they stay silent with no UI transition.
    func handlePausedCallback(snapshot: UIImage?) {
        let appState = AppState.shared
        guard appState.phase == .playing else { return }
        if EngineState.shared.isBackgroundPause { return }
        pauseSnapshot = snapshot
        pausedGame = appState.selectedGame
        withAnimation(.spring(duration: 0.25, bounce: 0)) {
            appState.phase = nil
        }
    }


    /// Phase change is delayed so the hero zoom animation plays while
    /// the library is still visible. The snapshot stays alive — PlayerView
    /// picks it up as a fade-out overlay so there's no flash at handoff.
    func resume() {
        guard pausedGame != nil else { return }
        pausedGame = nil
        snapshotCanFade = false
        mkxp_requestResume()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            AppState.shared.phase = .playing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.snapshotCanFade = true
            }
        }
    }


    func reset() {
        pauseSnapshot = nil
        snapshotCanFade = false
        pausedGame = nil
    }
}

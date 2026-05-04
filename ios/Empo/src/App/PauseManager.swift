import Foundation
import Observation
import SwiftUI

/// Pure data holder for pause state; no references to AppState.
/// Lifecycle methods that coordinate phase transitions live in AppState.
@MainActor @Observable
final class PauseManager {
    static let shared = PauseManager()

    var pausedGame: GameEntry?

    /// Frozen frame captured at pause time; used as a static double
    /// during the hero zoom animation (SDL can't participate in SwiftUI transitions).
    var pauseSnapshot: UIImage?

    /// True once the engine swaps its first frame after resume; signals
    /// PlayerView that it's safe to fade out the snapshot overlay.
    var snapshotCanFade = false

    private init() {}

    func reset() {
        pauseSnapshot = nil
        snapshotCanFade = false
        pausedGame = nil
    }
}

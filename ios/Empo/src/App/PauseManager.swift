import Foundation
import Observation
import SwiftUI

/// Pure data holder for pause state. No references to AppState.
/// Lifecycle methods that coordinate phase transitions live in AppState.
@MainActor @Observable
final class PauseManager {
    static let shared = PauseManager()

    var pausedGame: GameEntry?

    /// A frozen frame captured at pause time. It is a static double
    /// during the hero zoom animation (SDL cannot take part in
    /// SwiftUI transitions).
    var pauseSnapshot: UIImage?

    /// True once the engine swaps its first frame after resume. It
    /// signals PlayerView that the snapshot overlay can fade out
    /// safely.
    var snapshotCanFade = false

    private init() {}

    func reset() {
        pauseSnapshot = nil
        snapshotCanFade = false
        pausedGame = nil
    }
}

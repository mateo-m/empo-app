import Foundation
import Combine

/// The phases of the app lifecycle.
enum AppPhase: Equatable {
    case library
    case loading
    case playing
    case quitting
}

/// Central state machine driving all UI transitions.
/// Polls bridge functions and publishes state changes that SwiftUI reacts to.
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var phase: AppPhase = .library
    @Published var gameRect: CGRect = .zero
    @Published var showQuitConfirm = false

    private var pollTimer: Timer?
    private var terminationTimer: Timer?

    private init() {}

    // MARK: - Actions

    /// Called by GameLibraryView when a game is tapped.
    func selectGame(_ path: String) {
        phase = .loading
        mkxp_setGamePath(path)
        startGamePolling()
    }

    /// User tapped the quit button — show confirmation.
    func requestQuit() {
        showQuitConfirm = true
    }

    /// User confirmed quit — immediately show library, then tear down engine.
    func confirmQuit() {
        showQuitConfirm = false
        stopGamePolling()

        // Show library immediately (covers everything)
        phase = .library

        // Ask engine to shut down
        mkxp_requestTerminate()

        // Poll until engine confirms termination, then reset for next session
        terminationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            if mkxp_isEngineTerminated() != 0 {
                timer.invalidate()
                self?.terminationTimer = nil
                // Reload library in case anything changed
                GameLibrary.shared.reload()
            }
        }
    }

    // MARK: - Bridge Polling

    private func startGamePolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollBridge()
        }
    }

    func stopGamePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollBridge() {
        // Update game rect
        var x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0
        mkxp_getGameRect(&x, &y, &w, &h)
        let newRect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
        if newRect != gameRect {
            gameRect = newRect
        }

        // Check if game is ready (transition from loading to playing)
        if phase == .loading && mkxp_isGameReady() != 0 {
            phase = .playing
        }
    }
}

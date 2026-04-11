import Foundation
import SwiftUI
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
    @Published var selectedGame: GameEntry?

    private var pollTimer: Timer?
    private var terminationTimer: Timer?
    private let sessionHistoryPath: String

    private init() {
        let logsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        sessionHistoryPath = logsDir.appendingPathComponent("session-history.log").path

        // Reset session history on each app launch
        let dirty = GitInfo.dirty ? " (dirty)" : ""
        let launchTime = ISO8601DateFormatter().string(from: Date())
        var header = "mkxp-ios session history\n"
        header += "commit: \(GitInfo.commit)\(dirty)\n"
        header += "launched: \(launchTime)\n"
        header += "---\n"
        try? header.write(toFile: sessionHistoryPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Actions

    /// Called from NavigationLink's simultaneousGesture when user taps a card.
    func selectGame(_ game: GameEntry) {
        guard phase == .library else { return }
        selectedGame = game
        phase = .loading
        configureDebugLog(for: game)
        appendSessionHistory(game: game)
        mkxp_setGamePath(game.path)
        startGamePolling()
    }

    /// Creates a per-session debug log file if debug logs are enabled.
    private func configureDebugLog(for game: GameEntry) {
        guard AppSettings.shared.debugLogs else {
            mkxp_setDebugLogPath(nil)
            return
        }

        let logsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let slug = game.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(game.id)-\(slug)-\(timestamp).log"
        let logPath = logsDir.appendingPathComponent(filename).path

        // Write header with git info
        let dirty = GitInfo.dirty ? " (dirty)" : ""
        var header = "mkxp-ios debug log\n"
        header += "commit: \(GitInfo.commit)\(dirty)\n"
        header += "game: \(game.title) [\(game.id)]\n"
        header += "session: \(timestamp)\n"
        header += "---\n\n"
        try? header.write(toFile: logPath, atomically: true, encoding: .utf8)

        mkxp_setDebugLogPath(logPath)
    }

    private func appendSessionHistory(game: GameEntry) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\n[\(timestamp)] \(game.title) [\(game.id)]\n"
        if let data = entry.data(using: .utf8),
           let fh = FileHandle(forWritingAtPath: sessionHistoryPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        }
    }

    /// User tapped the quit button — show confirmation.
    func requestQuit() {
        showQuitConfirm = true
    }

    /// User confirmed quit — immediately show library, then tear down engine.
    func confirmQuit() {
        showQuitConfirm = false
        stopGamePolling()

        // Show library immediately — the NavigationStack pop provides
        // the reverse hero zoom animation, no additional fade needed.
        selectedGame = nil
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
            withAnimation(.easeOut(duration: 0.3)) {
                phase = .playing
            }
        }
    }
}

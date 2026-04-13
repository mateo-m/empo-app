import Foundation
import SwiftUI
import Observation

/// The phases of the app lifecycle.
enum AppPhase: Equatable {
    case library
    case loading
    case playing
    case quitting
}

/// Central state machine driving all UI transitions.
/// Registers callbacks with the C bridge to react to engine state changes.
@Observable
class AppState {
    static let shared = AppState()

    var phase: AppPhase = .library
    var gameRect: CGRect = .zero
    var showQuitConfirm = false
    var selectedGame: GameEntry?
    var errorMessage: String?

    /// The game that is currently paused in the background.
    /// Non-nil when the engine is alive but suspended on a condvar.
    var pausedGame: GameEntry?

    private let sessionHistoryPath: String
    private static let isoFormatter = ISO8601DateFormatter()
    private var sessionStartTime: Date?  // for play time tracking

    private init() {
        let logsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        sessionHistoryPath = logsDir.appendingPathComponent("session-history.log").path

        // Reset session history on each app launch
        let dirty = GitInfo.dirty ? " (dirty)" : ""
        let launchTime = Self.isoFormatter.string(from: Date())
        var header = "mkxp-ios session history\n"
        header += "commit: \(GitInfo.commit)\(dirty)\n"
        header += "launched: \(launchTime)\n"
        header += "---\n"
        try? header.write(toFile: sessionHistoryPath, atomically: true, encoding: .utf8)

        pruneOldLogs(in: logsDir)
        registerBridgeCallbacks()
    }

    /// Keep only the most recent log files, deleting the oldest ones.
    private func pruneOldLogs(in logsDir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.creationDateKey]) else { return }

        // Only consider per-session log files (UUID-slug-timestamp.log), not session-history.log
        let logFiles = files.filter { $0.lastPathComponent != "session-history.log" && $0.pathExtension == "log" }
        guard logFiles.count > AppSettings.shared.maxLogFiles else { return }

        let sorted = logFiles.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return d0 < d1
        }

        for file in sorted.prefix(sorted.count - AppSettings.shared.maxLogFiles) {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Actions

    /// Called from NavigationLink's simultaneousGesture when user taps a card.
    func selectGame(_ game: GameEntry) {
        // If this game is already paused, resume it instead
        if let paused = pausedGame, paused.id == game.id {
            resume()
            return
        }

        guard phase == .library, pausedGame == nil else { return }
        selectedGame = game
        phase = .loading

        // Apply per-game settings to mkxp.json before the engine reads it
        let gameDir = URL(fileURLWithPath: game.path)
        let settings = GameSettings.load(from: gameDir)
        settings.applyToConfig(in: gameDir)

        // Push bridge-only settings (not in mkxp.json)
        let alignment = settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment
        let postload = settings.postloadScripts ?? GameConfigDefaults.enginePostloadScripts
        mkxp_applyPerGameSettings(alignment.bridgeValue, postload)

        configureDebugLog(for: game)
        appendSessionHistory(game: game)
        sessionStartTime = Date()
        mkxp_setGamePath(game.path)
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
        let timestamp = Self.isoFormatter.string(from: Date())
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
        let timestamp = Self.isoFormatter.string(from: Date())
        let entry = "\n[\(timestamp)] \(game.title) [\(game.id)]\n"
        if let data = entry.data(using: .utf8),
           let fh = FileHandle(forWritingAtPath: sessionHistoryPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        }
    }

    /// Records the elapsed wall-clock play time for the current session
    /// and updates the game's metadata. Called when the engine terminates.
    func recordSessionPlayTime() {
        guard let game = selectedGame,
              let startTime = sessionStartTime else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        sessionStartTime = nil

        // Only record meaningful sessions (> 1 second)
        guard elapsed > 1 else { return }

        var metadata = GameMetadata.load(for: game.id)
        metadata.totalPlayTime = (metadata.totalPlayTime ?? 0) + elapsed
        metadata.lastPlayed = Date()
        metadata.save(for: game.id)
    }

    /// User tapped the quit button — show confirmation.
    func requestQuit() {
        guard AppSettings.shared.isEnabled(.gameQuit) else { return }
        showQuitConfirm = true
    }

    /// User confirmed quit — immediately show library, then tear down engine.
    func confirmQuit() {
        showQuitConfirm = false
        returnToLibrary()
    }

    /// Returns to the library and tears down the engine.
    /// Used by quit confirmation, error dismissal, and any other exit path.
    func returnToLibrary() {
        // requestTerminate unblocks the condvar (if paused) and pushes
        // SDL_QUIT. The engine will skip audio restoration because the
        // terminate flag is set before the condvar is signaled.
        mkxp_requestTerminate()
        selectedGame = nil
        pausedGame = nil
        phase = .library
    }

    /// Request the engine to pause and return to library.
    /// Called from the toolbar pause button.
    func requestPause() {
        guard phase == .playing else { return }
        isBackgroundPause = false
        mkxp_requestPause()
    }

    /// Pause the engine silently without leaving the player.
    /// Called when the app moves to the background; auto-resumes on foreground.
    func requestBackgroundPause() {
        guard phase == .playing else { return }
        isBackgroundPause = true
        mkxp_requestPause()
    }

    /// Resume the engine from a paused state and return to gameplay.
    func resume() {
        guard pausedGame != nil else { return }
        pausedGame = nil
        withAnimation(.easeOut(duration: 0.2)) {
            phase = .playing
        }
        mkxp_requestResume()
    }

    /// Whether the current pause was triggered by app backgrounding
    /// (silent — no UI transition to library).
    private var isBackgroundPause = false

    // MARK: - Bridge Callbacks

    /// Registers C function pointer callbacks with the engine bridge.
    /// These fire on the engine thread; each dispatches to main for UI updates.
    private func registerBridgeCallbacks() {
        // Game ready: loading -> playing
        mkxp_setGameReadyCallback({ _ in
            DispatchQueue.main.async {
                guard AppState.shared.phase == .loading else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    AppState.shared.phase = .playing
                }
            }
        }, nil)

        // Engine terminated: record play time, reload library after quit completes
        mkxp_setEngineTerminatedCallback({ _ in
            DispatchQueue.main.async {
                AppState.shared.recordSessionPlayTime()
                GameLibrary.shared.reload()
            }
        }, nil)

        // Game rect changed: update viewport for player layout
        mkxp_setGameRectChangedCallback({ x, y, w, h, _ in
            let newRect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
            DispatchQueue.main.async {
                if AppState.shared.gameRect != newRect {
                    AppState.shared.gameRect = newRect
                }
            }
        }, nil)

        // Error message: engine encountered a fatal error
        mkxp_setErrorMessageCallback({ msg, _ in
            guard let msg else { return }
            let message = String(cString: msg)
            DispatchQueue.main.async {
                AppState.shared.errorMessage = message
            }
        }, nil)

        // Engine paused: return to library (manual) or stay on player (background)
        mkxp_setPausedCallback({ _ in
            DispatchQueue.main.async {
                guard AppState.shared.phase == .playing else { return }
                if AppState.shared.isBackgroundPause {
                    // Silent pause — engine is suspended but UI stays on PlayerView.
                    // Will auto-resume when app returns to foreground.
                    return
                }
                AppState.shared.pausedGame = AppState.shared.selectedGame
                withAnimation(.easeOut(duration: 0.25)) {
                    AppState.shared.phase = .library
                }
            }
        }, nil)

        // Engine resumed: handled in resume() method
        mkxp_setResumedCallback({ _ in }, nil)
    }

}

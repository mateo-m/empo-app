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

    private let sessionHistoryPath: String
    private static let isoFormatter = ISO8601DateFormatter()

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
        guard phase == .library else { return }
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

    /// User tapped the quit button — show confirmation.
    func requestQuit() {
        guard AppSettings.shared.isEnabled(.gameQuit) else { return }
        showQuitConfirm = true
    }

    /// User confirmed quit — immediately show library, then tear down engine.
    func confirmQuit() {
        showQuitConfirm = false

        // Show library immediately — the NavigationStack pop provides
        // the reverse hero zoom animation, no additional fade needed.
        selectedGame = nil
        phase = .library

        // Ask engine to shut down. The engineTerminated callback
        // will fire when teardown is complete.
        mkxp_requestTerminate()
    }

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

        // Engine terminated: reload library after quit completes
        mkxp_setEngineTerminatedCallback({ _ in
            DispatchQueue.main.async {
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
    }
}

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

    /// Snapshot of the game viewport captured when pausing.
    /// The SDL window can't participate in SwiftUI transitions, so this
    /// frozen frame acts as a static double during the hero zoom animation.
    /// Positioned at `gameRect` in GameLoadingView to match the portrait layout.
    /// Cleared once the animation finishes and the live SDL view takes over.
    /// See docs/pause-resume.md.
    var pauseSnapshot: UIImage?

    /// Set to true when the engine swaps its first frame after resume.
    /// PlayerView watches this to know when the live SDL surface is
    /// visible and it's safe to fade out the snapshot overlay.
    var snapshotCanFade = false

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
        pauseSnapshot = nil
        snapshotCanFade = false
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
        pauseSnapshot = nil
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
    /// The phase change is delayed so the hero zoom animation can play
    /// while the library is still visible.  The snapshot stays alive —
    /// PlayerView picks it up as a fade-out overlay so there's no flash
    /// at the handoff, and controls are visible immediately.
    func resume() {
        guard pausedGame != nil else { return }
        pausedGame = nil
        snapshotCanFade = false
        mkxp_requestResume()

        // Delay phase change so the hero zoom plays with the library visible.
        // When phase flips to .playing, PlayerView appears instantly (via
        // .transition(.identity)) with the snapshot overlay at gameRect.
        // The library fades out underneath — the snapshot stays fully
        // visible because PlayerView's copy is at full opacity throughout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // Instant phase change — no animation.  PlayerView appears
            // with the snapshot overlay at the exact same gameRect
            // position, so the handoff is pixel-perfect.  An animated
            // fade would make the library grid visible behind
            // GameLoadingView as it becomes semi-transparent.
            self.phase = .playing
            // Small delay so the resume snapshot settles after the
            // hero zoom before fading.  Mirrors the fresh-start delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.snapshotCanFade = true
            }
        }
    }

    /// Resume the engine if it was paused by a background transition.
    /// Called when the app returns to the foreground.
    func resumeFromBackground() {
        guard phase == .playing, mkxp_isPaused() else { return }
        mkxp_requestResume()
    }

    /// Whether the current pause was triggered by app backgrounding
    /// (silent — no UI transition to library).
    private var isBackgroundPause = false

    // MARK: - Bridge Callbacks

    /// Registers C function pointer callbacks with the engine bridge.
    /// These fire on the engine thread; each dispatches to main for UI updates.
    private func registerBridgeCallbacks() {
        // First frame rendered: fires for both fresh starts and resumes.
        // For fresh starts (phase == .loading), transition to .playing.
        // For resumes (phase == .playing), signal the snapshot can fade.
        mkxp_setFrameRenderedCallback({ _ in
            DispatchQueue.main.async {
                let state = AppState.shared
                if state.phase == .loading {
                    // Small delay so the loading screen settles after the
                    // hero zoom before dissolving.  Without this, the
                    // artwork "flashes" for a split second because the
                    // engine renders its first frame almost immediately.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard state.phase == .loading else { return }
                        Haptics.success()
                        withAnimation(.spring(duration: 0.3, bounce: 0)) {
                            state.phase = .playing
                        }
                    }
                } else if state.phase == .playing {
                    state.snapshotCanFade = true
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

        // Engine paused: capture snapshot and return to library (manual) or stay on player (background)
        mkxp_setPausedCallback({ _ in
            // Capture snapshot on the engine thread (pointer is valid until next pause/reset)
            var snapshotImage: UIImage?
            var w: Int32 = 0
            var h: Int32 = 0
            if let ptr = mkxp_getSnapshotRGBA(&w, &h), w > 0, h > 0 {
                let bytesPerRow = Int(w) * 4
                let totalBytes = bytesPerRow * Int(h)
                let data = Data(bytes: ptr, count: totalBytes)
                if let provider = CGDataProvider(data: data as CFData),
                   let cgImage = CGImage(
                       width: Int(w), height: Int(h),
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent) {
                    snapshotImage = UIImage(cgImage: cgImage)
                }
            }

            DispatchQueue.main.async {
                guard AppState.shared.phase == .playing else { return }
                if AppState.shared.isBackgroundPause {
                    // Silent pause — engine is suspended but UI stays on PlayerView.
                    // Will auto-resume when app returns to foreground.
                    return
                }
                AppState.shared.pauseSnapshot = snapshotImage
                AppState.shared.pausedGame = AppState.shared.selectedGame
                withAnimation(.spring(duration: 0.25, bounce: 0)) {
                    AppState.shared.phase = .library
                }
            }
        }, nil)

        // Engine resumed: handled in resume() method
        mkxp_setResumedCallback({ _ in }, nil)
    }

}

import Foundation
import SwiftUI
import Observation

enum GamePhase: Equatable {
    case loading
    case playing
}

@MainActor @Observable
class AppState {
    static let shared = AppState()

    var phase: GamePhase?
    var selectedGame: GameEntry?
    var errorMessage: String?

    var pausedGame: GameEntry?

    private let sessionHistoryPath: String
    private static let isoFormatter = ISO8601DateFormatter()
    private var sessionStartTime: Date?

    private init() {
        let logsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        sessionHistoryPath = logsDir.appendingPathComponent("session-history.log").path

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

    /// Keep only the most recent log files.
    private func pruneOldLogs(in logsDir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let logFiles = files.filter { $0.lastPathComponent != "session-history.log" && $0.pathExtension == "log" }
        let maxLogFiles = UserDefaults.standard.object(forKey: "maxLogFiles") as? Int ?? 20
        guard logFiles.count > maxLogFiles else { return }

        let sorted = logFiles.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return d0 < d1
        }

        for file in sorted.prefix(sorted.count - maxLogFiles) {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Actions

    func selectGame(_ game: GameEntry) {
        if let paused = pausedGame, paused.id == game.id {
            resume()
            return
        }

        guard phase == nil, pausedGame == nil else { return }
        selectedGame = game
        EngineState.shared.reset()
        phase = .loading

        let gameDir = URL(fileURLWithPath: game.path)
        let settings = GameSettings.load(from: gameDir)
        settings.applyToConfig(in: gameDir)

        // These settings go through the bridge, not mkxp.json
        let alignment = settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment
        let postload = settings.postloadScripts ?? GameConfigDefaults.enginePostloadScripts
        mkxp_applyPerGameSettings(alignment.bridgeValue, postload)

        configureDebugLog(for: game)
        appendSessionHistory(game: game)
        sessionStartTime = Date()
        mkxp_setGamePath(game.path)
    }

    private func configureDebugLog(for game: GameEntry) {
        guard UserDefaults.standard.bool(forKey: "debugLogs") else {
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

    func recordSessionPlayTime() {
        guard let game = selectedGame,
              let startTime = sessionStartTime else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        sessionStartTime = nil

        guard elapsed > 1 else { return }

        var metadata = GameMetadata.load(for: game.id)
        metadata.totalPlayTime = (metadata.totalPlayTime ?? 0) + elapsed
        metadata.lastPlayed = Date()
        metadata.save(for: game.id)
    }

    /// Returns to the library and tears down the engine.
    func returnToLibrary() {
        // requestTerminate unblocks the condvar (if paused) and pushes
        // SDL_QUIT. The terminate flag is set first so the engine skips
        // audio restoration when it wakes from the condvar.
        mkxp_requestTerminate()
        selectedGame = nil
        pausedGame = nil
        EngineState.shared.reset()
        phase = nil
    }

    /// Phase change is delayed so the hero zoom animation plays while
    /// the library is still visible. The snapshot stays alive — PlayerView
    /// picks it up as a fade-out overlay so there's no flash at handoff.
    func resume() {
        guard pausedGame != nil else { return }
        pausedGame = nil
        EngineState.shared.snapshotCanFade = false
        mkxp_requestResume()

        // Delay so the hero zoom plays before PlayerView appears.
        // No animation wrapper — an animated fade would expose the
        // library grid behind the semi-transparent loading view.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.phase = .playing
            // Let the snapshot settle before fading to live SDL.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    EngineState.shared.snapshotCanFade = true
            }
        }
    }

    // MARK: - Bridge Callbacks

    /// All callbacks fire on the engine thread; each dispatches to main.
    private func registerBridgeCallbacks() {
        // First frame rendered — fresh start transitions to .playing,
        // resume signals the snapshot can fade.
        mkxp_setFrameRenderedCallback({ _ in
            DispatchQueue.main.async {
                let state = AppState.shared
                if state.phase == .loading {
                    // Delay so the loading screen settles after the hero
                    // zoom. Without this the artwork flashes briefly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard state.phase == .loading else { return }
                        Haptics.success()
                        withAnimation(.spring(duration: 0.3, bounce: 0)) {
                            state.phase = .playing
                        }
                    }
                } else if state.phase == .playing {
                    EngineState.shared.snapshotCanFade = true
                }
            }
        }, nil)

        mkxp_setEngineTerminatedCallback({ _ in
            DispatchQueue.main.async {
                AppState.shared.recordSessionPlayTime()
                GameLibrary.shared.reload()
            }
        }, nil)

        mkxp_setGameRectChangedCallback({ x, y, w, h, _ in
            let newRect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
            DispatchQueue.main.async {
                let engineState = EngineState.shared
                if engineState.gameRect != newRect {
                    engineState.gameRect = newRect
                }
            }
        }, nil)

        mkxp_setErrorMessageCallback({ msg, _ in
            guard let msg else { return }
            let message = String(cString: msg)
            DispatchQueue.main.async {
                AppState.shared.errorMessage = message
            }
        }, nil)

        // Engine paused — capture snapshot on the engine thread
        // (pointer is only valid until next pause/reset).
        mkxp_setPausedCallback({ _ in
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
                let appState = AppState.shared
                let engineState = EngineState.shared
                guard appState.phase == .playing else { return }
                if engineState.isBackgroundPause {
                    // Silent pause — UI stays on PlayerView, auto-resumes on foreground.
                    return
                }
                engineState.pauseSnapshot = snapshotImage
                appState.pausedGame = appState.selectedGame
                withAnimation(.spring(duration: 0.25, bounce: 0)) {
                    appState.phase = nil
                }
            }
        }, nil)

        // Empty — resume logic lives in resume()
        mkxp_setResumedCallback({ _ in }, nil)
    }

}

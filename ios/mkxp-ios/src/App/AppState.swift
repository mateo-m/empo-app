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
    var engineReady = false
    private(set) var pendingCrashRecovery = false
    private var terminationExpected = false

    // When returnToLibrary() asks the engine to terminate, we arm a
    // watchdog that fires after a few seconds. If the engine-terminated
    // callback cleared this token by then, the RGSS thread ack'd cleanly
    // and there is nothing to do. Otherwise the RGSS thread is stuck
    // and we surface the hang alert immediately - without waiting for
    // main.cpp's 10s timeout, which would otherwise fire on the NEXT
    // session's Loading view and confuse the user.
    private var pendingTerminationToken: UUID?
    private static let hangWatchdogSeconds: UInt64 = 3

    static let logsDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)

    private let sessionHistoryPath: String
    private static let isoFormatter = ISO8601DateFormatter()
    private var sessionStartTime: Date?

    private static let crashMarkerURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(".session-active")

    private static func commitSuffix() -> String {
        GitInfo.dirty ? " (dirty)" : ""
    }

    private static func logHeader(title: String, extras: [String] = []) -> String {
        var header = "\(title)\n"
        header += "commit: \(GitInfo.commit)\(commitSuffix())\n"
        for line in extras {
            header += "\(line)\n"
        }
        header += "---\n"
        return header
    }

    private init() {
        let logsDir = Self.logsDirectory
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        sessionHistoryPath = logsDir.appendingPathComponent("session-history.log").path

        let launchTime = Self.isoFormatter.string(from: Date())
        let header = Self.logHeader(title: "mkxp-ios session history", extras: ["launched: \(launchTime)"])
        try? header.write(toFile: sessionHistoryPath, atomically: true, encoding: .utf8)

        if FileManager.default.fileExists(atPath: Self.crashMarkerURL.path) {
            pendingCrashRecovery = true
        }

        pruneOldLogs(in: logsDir)
        registerBridgeCallbacks()
    }

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


    func selectGame(_ game: GameEntry) {
        let pauseManager = PauseManager.shared
        if let paused = pauseManager.pausedGame, paused.id == game.id {
            resumePausedGame()
            return
        }

        guard phase == nil, pauseManager.pausedGame == nil else { return }
        selectedGame = game
        PauseManager.shared.reset()
        phase = .loading

        let gameDir = URL(fileURLWithPath: game.path)
        let settings = GameSettings.load(from: gameDir)
        settings.applyToConfig(in: gameDir)

        // These settings go through the bridge, not mkxp.json
        let alignment = settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment
        let postload = settings.postloadScripts ?? GameConfigDefaults.enginePostloadScripts
        mkxp_applyPerGameSettings(alignment.bridgeValue, postload)

        FileManager.default.createFile(atPath: Self.crashMarkerURL.path, contents: nil)

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

        let logsDir = Self.logsDirectory
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let slug = game.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let timestamp = Self.isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(game.id)-\(slug)-\(timestamp).log"
        let logPath = logsDir.appendingPathComponent(filename).path

        let header = Self.logHeader(title: "mkxp-ios debug log", extras: [
            "game: \(game.title) [\(game.id)]",
            "session: \(timestamp)",
        ]) + "\n"
        try? header.write(toFile: logPath, atomically: true, encoding: .utf8)

        mkxp_setDebugLogPath(logPath)
    }

    private func appendSessionHistory(game: GameEntry) {
        let timestamp = Self.isoFormatter.string(from: Date())
        let entry = "\n[\(timestamp)] \(game.title) [\(game.id)]\n"
        if let data = entry.data(using: .utf8),
           let fh = FileHandle(forWritingAtPath: sessionHistoryPath) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            _ = try? fh.write(contentsOf: data)
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

    private static let crashMessage = "It looks like the game didn't exit cleanly last time. "
        + "Your save data should be fine."

    func consumeCrashRecovery() {
        guard pendingCrashRecovery else { return }
        pendingCrashRecovery = false
        errorMessage = Self.crashMessage
    }

    func dismissCrashRecovery() {
        removeCrashMarker()
        errorMessage = nil
    }

    func returnToLibrary() {
        terminationExpected = true
        recordSessionPlayTime()
        removeCrashMarker()
        mkxp_requestTerminate()
        selectedGame = nil
        engineReady = false
        PauseManager.shared.reset()
        phase = nil
        armHangWatchdog()
    }

    private func armHangWatchdog() {
        let token = UUID()
        pendingTerminationToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.hangWatchdogSeconds * 1_000_000_000)
            guard let self else { return }
            // If the engine-terminated callback already cleared the token
            // (or replaced it with a newer one), do nothing.
            guard self.pendingTerminationToken == token else { return }
            self.pendingTerminationToken = nil
            // Engine is stuck. Mark the bridge state so the alert's OK
            // button force-quits, then surface the generic message.
            mkxp_setEngineHung()
            self.errorMessage = AppState.hangMessage
        }
    }

    private static let hangMessage =
        "The previous game stopped responding and will now close."


    // MARK: - Pause lifecycle
    // These methods coordinate PauseManager state with phase transitions.
    // PauseManager is a pure data holder — all AppState mutations stay here.

    func requestPause() {
        guard AppSettings.shared.isEnabled(.gamePause),
              phase == .playing else { return }
        EngineState.shared.isBackgroundPause = false
        mkxp_requestPause()
    }

    /// Called on the main thread from the bridge's paused callback.
    /// Background pauses are ignored — they stay silent with no UI transition.
    func handlePause(snapshot: UIImage?) {
        guard phase == .playing else { return }
        if EngineState.shared.isBackgroundPause { return }
        let pm = PauseManager.shared
        pm.pauseSnapshot = snapshot
        pm.pausedGame = selectedGame
        withAnimation(.spring(duration: 0.25, bounce: 0)) {
            phase = nil
        }
    }

    /// Phase change is delayed so the hero zoom animation plays while
    /// the library is still visible. The snapshot stays alive — PlayerView
    /// picks it up as a fade-out overlay so there's no flash at handoff.
    func resumePausedGame() {
        let pm = PauseManager.shared
        guard pm.pausedGame != nil else { return }
        pm.pausedGame = nil
        pm.snapshotCanFade = false
        mkxp_requestResume()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.phase = .playing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pm.snapshotCanFade = true
            }
        }
    }


    private func removeCrashMarker() {
        try? FileManager.default.removeItem(at: Self.crashMarkerURL)
    }

    /// Remove the crash marker when backgrounding a healthy session.
    /// Re-creates it when the app returns to foreground so a subsequent
    /// crash after resume is still detected.
    func clearCrashMarkerForBackground() {
        removeCrashMarker()
    }

    func restoreCrashMarkerForForeground() {
        FileManager.default.createFile(atPath: Self.crashMarkerURL.path, contents: nil)
    }

    private func registerBridgeCallbacks() {
        // First frame rendered — fresh start transitions to .playing,
        // resume signals the snapshot can fade.
        mkxp_setFrameRenderedCallback({ _ in
            Task { @MainActor in
                let state = AppState.shared
                if state.phase == .loading, !state.engineReady {
                    Haptics.success()
                    state.engineReady = true
                    AppSettings.shared.syncRendererWithEngine()
                } else if state.phase == .playing {
                    PauseManager.shared.snapshotCanFade = true
                }
            }
        }, nil)

        mkxp_setEngineTerminatedCallback({ _ in
            Task { @MainActor in
                let state = AppState.shared
                // Engine ack'd termination, so the hang watchdog armed
                // by returnToLibrary() should not fire.
                state.pendingTerminationToken = nil
                state.recordSessionPlayTime()
                state.removeCrashMarker()
                GameLibrary.shared.reload()

                if !state.terminationExpected && state.phase != nil {
                    // Preserve a Ruby/engine error message if the error callback
                    // already set one; otherwise fall back to the generic crash text.
                    // Intentionally do NOT set phase = nil here: if we set phase = nil
                    // while an error alert is already presenting, SwiftUI swallows the
                    // NavigationStack pop. Leaving phase non-nil means the alert OK
                    // button sees phase != nil, calls returnToLibrary(), and the pop
                    // happens cleanly after the alert is dismissed.
                    if state.errorMessage == nil {
                        state.errorMessage = AppState.crashMessage
                    }
                    state.selectedGame = nil
                    state.engineReady = false
                    PauseManager.shared.reset()
                }
                state.terminationExpected = false
            }
        }, nil)

        mkxp_setGameRectChangedCallback({ x, y, w, h, _ in
            let newRect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
            Task { @MainActor in
                let engineState = EngineState.shared
                if engineState.gameRect != newRect {
                    engineState.gameRect = newRect
                }
            }
        }, nil)

        mkxp_setErrorMessageCallback({ msg, _ in
            guard let msg else { return }
            let message = String(cString: msg)
            Task { @MainActor in
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

            Task { @MainActor in
                AppState.shared.handlePause(snapshot: snapshotImage)
            }
        }, nil)

        mkxp_setResumedCallback({ _ in }, nil)
    }

}

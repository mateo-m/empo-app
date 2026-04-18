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

    // Continuations waiting for the engine-terminated callback to fire,
    // used by selectGame() to wait for cross-session teardown before
    // handing the engine a new path. Drained in registerBridgeCallbacks
    // when the callback runs. No polling, no timeouts - the hang
    // watchdog above handles the truly-stuck case by force-quitting
    // the app, which also implicitly drains these (the process exits).
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    private func awaitEngineTermination() async {
        // Fast path: engine is already terminated (previous session
        // finished its cross-session cleanup and is parked in
        // waitForGamePath) - hand off immediately.
        if mkxp_isEngineTerminated() != 0 { return }
        // No termination is in flight - we're on cold boot, the RGSS
        // thread is waiting for its FIRST game path. Hand off
        // immediately without parking.
        if pendingTerminationToken == nil { return }
        // A termination is actively in flight. Park until the
        // engine-terminated callback drains our continuation.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            terminationWaiters.append(cont)
        }
    }

    private func drainTerminationWaiters() {
        let pending = terminationWaiters
        terminationWaiters.removeAll()
        for cont in pending { cont.resume() }
    }

    static let logsDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)

    private let sessionHistoryPath: String
    private static let isoFormatter = ISO8601DateFormatter()
    private var sessionStartTime: Date?

    private static let crashMarkerURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(".session-active")

    /// The crash marker is written each time a game session starts and
    /// removed when it ends cleanly. If it's still on disk on the
    /// next app launch, something killed the previous session
    /// unexpectedly (user-killed-app, OOM, C++ crash).
    ///
    /// But reinstalls also leave the marker behind, since the
    /// Documents directory is preserved across installs. We don't
    /// want to accuse a fresh install of "not exiting cleanly" when
    /// the user simply redeployed from Xcode or updated via the App
    /// Store. Compare the marker's mtime with the executable's
    /// bundle mtime: if the binary is newer, the marker is stale.
    private static func isCrashMarkerFromCurrentInstall() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: crashMarkerURL.path) else { return false }

        guard let markerAttrs = try? fm.attributesOfItem(atPath: crashMarkerURL.path),
              let markerMtime = markerAttrs[.modificationDate] as? Date else {
            // Couldn't stat the marker - assume current install so we
            // don't silently swallow a real crash. Conservative default.
            return true
        }

        // Bundle's executable is replaced on every install. Its mtime
        // is a reliable "install time" proxy across simulators, real
        // devices, TestFlight, and App Store updates.
        guard let execPath = Bundle.main.executablePath,
              let bundleAttrs = try? fm.attributesOfItem(atPath: execPath),
              let bundleMtime = bundleAttrs[.modificationDate] as? Date else {
            return true
        }

        return markerMtime > bundleMtime
    }

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
        let header = Self.logHeader(title: "\(AppInfo.name) session history", extras: ["launched: \(launchTime)"])
        try? header.write(toFile: sessionHistoryPath, atomically: true, encoding: .utf8)

        if Self.isCrashMarkerFromCurrentInstall() {
            pendingCrashRecovery = true
        } else {
            // Stale marker from a previous install (dev redeploy,
            // TestFlight update, reinstall from App Store). The
            // session it was recording can't have been in this
            // binary, so treat the crash state as already resolved
            // and clean up. Avoids a spurious "didn't exit cleanly"
            // alert on first launch after a redeploy.
            try? FileManager.default.removeItem(at: Self.crashMarkerURL)
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

        // Wait for the RGSS thread to actually finish tearing down any
        // previous session before we feed it the new path. If we call
        // mkxp_setGamePath too early, the engine's own
        // mkxp_setEngineTerminated() runs after us and clears the path
        // flag we just set, leaving the next session stuck in
        // waitForGamePath forever.
        //
        // awaitEngineTermination returns immediately when no previous
        // session is running (isEngineTerminated is already true), and
        // otherwise parks on a continuation that the engine-terminated
        // callback wakes up. No polling, no wall-clock deadline: the
        // hang watchdog in returnToLibrary is what handles a truly
        // stuck RGSS thread by force-quitting the app.
        //
        // The loading view is already on screen throughout this wait,
        // so it doubles as a "quitting" indicator when the user quickly
        // taps a new game right after quitting.
        Task { @MainActor in
            await awaitEngineTermination()
            mkxp_setGamePath(game.path)
        }
    }

    private func configureDebugLog(for game: GameEntry) {
        guard AppSettings.shared.debugLogs else {
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

        let header = Self.logHeader(title: "\(AppInfo.name) debug log", extras: [
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

        // Only talk to the engine if it's still running. After a crash
        // the terminated callback has already fired and re-arming the
        // hang watchdog here would trip a spurious "previous game
        // stopped responding" alert 3s later.
        let engineWasRunning = mkxp_isEngineTerminated() == 0
        if engineWasRunning {
            mkxp_requestTerminate()
        }

        selectedGame = nil
        engineReady = false
        PauseManager.shared.reset()
        phase = nil

        if engineWasRunning {
            armHangWatchdog()
        }
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
        "The previous game stopped responding. The app will now close."

    /// Hard-deadline force-quit used by the loading-view escape hatch.
    ///
    /// The regular hang watchdog (armHangWatchdog) shows an alert and
    /// waits for the user to tap OK before calling exit(0). When the
    /// user tapped "Quit to library" during loading, they're already
    /// stuck and signaling urgency - making them read and dismiss an
    /// alert before the app finally closes is bad UX. This helper
    /// skips the alert entirely and exit(0)s directly after the
    /// deadline, while still giving the engine a generous window to
    /// terminate cleanly if it can.
    ///
    /// The normal engine-terminated callback path is expected to clear
    /// `pendingTerminationToken` before the deadline in the happy
    /// case, which cancels this helper.
    func armLoadingEscapeForceQuit() {
        let token = pendingTerminationToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            // Only force-quit if the original termination request the
            // escape hatch kicked off is still pending (i.e. the engine
            // never ack'd). Tokens match on reentrant quits too, so a
            // second tap doesn't double-arm.
            guard self.pendingTerminationToken == token,
                  token != nil else { return }
            mkxp_setEngineHung()
            exit(0)
        }
    }


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
        withAnimation(Motion.snappy) {
            phase = nil
        }
    }

    /// Phase change is delayed so the hero zoom animation plays while
    /// the library is still visible. The snapshot stays alive — PlayerView
    /// picks it up as a fade-out overlay so there's no flash at handoff.
    ///
    /// The `pm.pausedGame == nil` guard in the Task prevents a stray
    /// `phase = .playing` after the user cancelled mid-resume by
    /// returning to the library; previously the chained asyncAfter
    /// calls could race past `returnToLibrary()` and put the app back
    /// into .playing with no game loaded.
    func resumePausedGame() {
        let pm = PauseManager.shared
        guard pm.pausedGame != nil else { return }
        pm.pausedGame = nil
        pm.snapshotCanFade = false
        mkxp_requestResume()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, pm.pausedGame == nil else { return }
            self.phase = .playing
            // The frame-rendered callback in registerBridgeCallbacks
            // also flips `snapshotCanFade` once the engine has drawn
            // a real frame; this timed fallback just guarantees the
            // snapshot fades out even if the callback is delayed.
            try? await Task.sleep(for: .milliseconds(300))
            pm.snapshotCanFade = true
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
                // Wake any selectGame awaiters so the pending new
                // session can hand its path to the RGSS thread.
                state.drainTerminationWaiters()
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

        // Engine paused - capture snapshot while lock is held.
        mkxp_setPausedCallback({ _ in
            var snapshotImage: UIImage?
            var w: Int32 = 0
            var h: Int32 = 0
            if mkxp_getSnapshotSize(&w, &h), w > 0, h > 0 {
                let totalBytes = Int(w) * Int(h) * 4
                var buffer = [UInt8](repeating: 0, count: totalBytes)
                if mkxp_copySnapshotRGBA(&buffer, Int32(totalBytes), &w, &h) {
                    let data = Data(buffer)
                    let bytesPerRow = Int(w) * 4
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
            }

            Task { @MainActor in
                AppState.shared.handlePause(snapshot: snapshotImage)
            }
        }, nil)

        mkxp_setResumedCallback({ _ in }, nil)
    }

}

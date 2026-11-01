// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import Observation

/// Starts each game in an Empo Player process of its own, and records
/// its play time.
///
/// Empo Player has only the sandbox and inherit entitlements, so a
/// child that Process starts runs in Empo's sandbox and container. The
/// games' saves stay in Empo's container, as on iOS.
@MainActor @Observable
final class GameLauncher {
    static let shared = GameLauncher()

    /// A game that could not start, or that stopped by a crash.
    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        /// The session's debug log, when debug logs are on.
        let logURL: URL?
    }

    /// The library window shows it as an alert, then sets it to nil.
    var lastFailure: Failure?

    private struct Session {
        let gameID: String
        let gameTitle: String
        let process: Process
        let logger: SessionLogger
    }

    private var sessions: [String: Session] = [:]

    private init() {}

    private static let playerURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/Empo Player.app/Contents/MacOS/Empo Player")

    func isPlaying(_ game: GameEntry) -> Bool { sessions[game.id] != nil }

    var playingGameIDs: [String] { Array(sessions.keys) }

    func play(_ game: GameEntry) throws {
        if let session = sessions[game.id] {
            NSRunningApplication(processIdentifier: session.process.processIdentifier)?.activate()
            return
        }
        let start = try GameStart(game: game)
        DataDirectory.ensureFontsRoot()

        let logger = SessionLogger()
        logger.onPlayTimeFlushed = { GameLibrary.shared.refreshGameEntry(id: $0) }
        logger.openDebugLog(for: game, container: start.container, enabled: AppSettings.shared.debugLogs)
        CoreSettingsRecorder.settings = []
        start.core.launch(start.container)

        let launch = PlayerLaunch(
            title: game.title,
            corePath: start.coreBinaryURL.path,
            gamePath: game.path,
            userDataDirectory: start.userDataDirectory?.path,
            fontsDirectory: DataDirectory.fontsRootURL.path,
            verticalAlignment: (start.settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment)
                .bridgeValue,
            fixedAspectRatio: start.settings.fixedAspectRatio
                ?? start.core.displayDefaults(for: start.container).fixedAspectRatio
                ?? GameConfigDefaults.engineFixedAspectRatio,
            settings: CoreSettingsRecorder.settings,
            debugLogPath: logger.logURL?.path,
            caBundlePath: CABundleStore.effectivePath,
            fastForwardMultiplier: start.settings.speedMultiplier.flatMap { $0 >= 2 ? $0 : nil },
            iconPath: game.artworkPath)

        let process = Process()
        process.executableURL = Self.playerURL
        process.arguments = try launch.arguments()
        let messages = Pipe()
        process.standardOutput = messages
        process.terminationHandler = { process in
            Task { @MainActor in GameLauncher.shared.ended(process) }
        }
        try process.run()
        logger.beginSession(for: game, container: start.container)
        logger.note("\(game.title) starts on \(start.core.framework) \(start.core.version) in Empo Player")
        sessions[game.id] = Session(gameID: game.id, gameTitle: game.title, process: process, logger: logger)
        Task { [weak self] in
            do {
                for try await line in messages.fileHandleForReading.bytes.lines {
                    self?.received(line, from: process)
                }
            } catch {
                logger.note("Empo cannot read the messages of Empo Player: \(error)")
            }
        }
    }

    private func session(of process: Process) -> Session? {
        sessions.values.first { $0.process === process }
    }

    private func entry(_ session: Session) -> GameEntry? {
        GameLibrary.shared.games.first { $0.id == session.gameID }
    }

    /// The SessionLogger timer runs only while the game is not paused,
    /// as on iOS.
    private func received(_ line: String, from process: Process) {
        guard let session = session(of: process), let message = PlayerMessage(rawValue: line) else { return }
        switch message {
        case .paused:
            session.logger.recordSessionPlayTime(for: entry(session))
        case .resumed:
            if let game = entry(session) { session.logger.resumeSessionTiming(for: game) }
        }
    }

    private func ended(_ process: Process) {
        guard let session = session(of: process) else { return }
        sessions.removeValue(forKey: session.gameID)
        let status = process.terminationStatus
        let crashed = process.terminationReason == .uncaughtSignal
        session.logger.note("Empo Player ended with \(crashed ? "signal" : "status") \(status)")
        if !crashed, status == 64 {
            session.logger.note("Empo Player could not read the launch data from Empo")
        }
        session.logger.recordSessionPlayTime(for: entry(session))
        guard crashed || ![0, 128 + SIGTERM].contains(status) else { return }
        // 64: the launch data was wrong. 70: the core did not open.
        let title =
            !crashed && [64, 70].contains(status)
            ? String(localized: "\"\(session.gameTitle)\" couldn't start.")
            : String(localized: "\"\(session.gameTitle)\" quit unexpectedly.")
        lastFailure = Failure(title: title, logURL: session.logger.logURL)
    }

    /// Asks once before quit closes the open games. The alert's
    /// checkbox turns the question off.
    func confirmQuit() -> NSApplication.TerminateReply {
        if !sessions.isEmpty, !AppSettings.shared.quitClosesGamesWithoutAsking {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "Quit \(AppInfo.name)?", comment: "Alert title. The placeholder is the app's name."
            )
            alert.informativeText = String(
                localized:
                    "\(sessions.count) open games will close too. Progress you haven't saved will be lost.",
                comment: "Alert text when the user quits the app while games run in their own windows.")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.showsSuppressionButton = true
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            if alert.suppressionButton?.state == .on {
                AppSettings.shared.quitClosesGamesWithoutAsking = true
            }
        }
        for session in sessions.values {
            session.logger.recordSessionPlayTime(for: entry(session))
            session.process.terminate()
        }
        sessions.removeAll()
        return .terminateNow
    }
}

/// Collects what a core's `launch(_:)` sends with gamecore_setSetting.
/// Empo Player gives the settings to the core in its own process.
enum CoreSettingsRecorder {
    nonisolated(unsafe) static var settings: [PlayerLaunch.Setting] = []
}

@_cdecl("gamecore_setSetting")
func recordCoreSetting(_ key: UnsafePointer<CChar>?, _ value: UnsafePointer<CChar>?) {
    guard let key else { return }
    CoreSettingsRecorder.settings.append(
        PlayerLaunch.Setting(key: String(cString: key), value: value.map { String(cString: $0) } ?? ""))
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit

/// Starts each game in an Empo Player process of its own, and records
/// its play time.
///
/// Empo Player has only the sandbox and inherit entitlements, so a
/// child that Process starts runs in Empo's sandbox and container. The
/// games' saves stay in Empo's container, as on iOS.
@MainActor
final class GameLauncher {
    static let shared = GameLauncher()

    private struct Session {
        let process: Process
        let logger: SessionLogger
    }

    private var sessions: [String: Session] = [:]

    private init() {}

    private static let playerURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/Empo Player.app/Contents/MacOS/Empo Player")

    struct LaunchError: LocalizedError {
        let errorDescription: String?
    }

    func isPlaying(_ game: GameEntry) -> Bool { sessions[game.id] != nil }

    var playingGameIDs: [String] { Array(sessions.keys) }

    func play(_ game: GameEntry) throws {
        if let session = sessions[game.id] {
            NSRunningApplication(processIdentifier: session.process.processIdentifier)?.activate()
            return
        }
        guard let container = game.container, let core = GameCores.core(forGameAt: container.gameURL) else {
            return
        }
        guard let binary = core.binaryURL else {
            throw LaunchError(errorDescription: core.notInThisBuildMessage)
        }
        try? container.ensureSubdirs()
        let userData = DataDirectory.resolveAndPrepare(for: container, core: core)
            .map(DataDirectory.engineSpelling(of:))
        DataDirectory.ensureFontsRoot()
        let settings = GameSettings.load(from: container.empoStateURL)

        let logger = SessionLogger()
        logger.onPlayTimeFlushed = { GameLibrary.shared.refreshGameEntry(id: $0) }
        CoreSettingsRecorder.settings = []
        core.launch(container)
        logger.beginSession(for: game, container: container, debugLogsEnabled: AppSettings.shared.debugLogs)

        let launch = PlayerLaunch(
            title: game.title,
            corePath: binary.path,
            gamePath: game.path,
            userDataDirectory: userData?.path,
            fontsDirectory: DataDirectory.fontsRootURL.path,
            verticalAlignment: Int32(
                (settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment).bridgeValue
                    .rawValue),
            settings: CoreSettingsRecorder.settings,
            debugLogPath: logger.logURL?.path,
            caBundlePath: CABundleStore.effectivePath,
            fastForwardMultiplier: settings.speedMultiplier.flatMap { $0 >= 2 ? $0 : nil },
            iconPath: game.artworkPath)

        let process = Process()
        process.executableURL = Self.playerURL
        process.arguments = try launch.arguments()
        let gameID = game.id
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in GameLauncher.shared.ended(gameID: gameID, status: status) }
        }
        try process.run()
        logger.note("\(game.title) starts on \(core.framework) \(core.version) in Empo Player")
        sessions[game.id] = Session(process: process, logger: logger)
    }

    private func ended(gameID: String, status: Int32) {
        guard let session = sessions.removeValue(forKey: gameID) else { return }
        session.logger.note("Empo Player ended with status \(status)")
        session.logger.recordSessionPlayTime(for: GameLibrary.shared.games.first { $0.id == gameID })
    }

    /// Asks once before quit closes the open games. The alert's
    /// checkbox turns the question off.
    func confirmQuit() -> NSApplication.TerminateReply {
        if !sessions.isEmpty, !UserDefaults.standard.bool(forKey: DefaultsKey.quitClosesGamesWithoutAsking) {
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
                UserDefaults.standard.set(true, forKey: DefaultsKey.quitClosesGamesWithoutAsking)
            }
        }
        recordAllPlayTime()
        for session in sessions.values { session.process.terminate() }
        sessions.removeAll()
        return .terminateNow
    }

    private func recordAllPlayTime() {
        for (gameID, session) in sessions {
            session.logger.recordSessionPlayTime(for: GameLibrary.shared.games.first { $0.id == gameID })
        }
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

// SessionLogger sends the session log to the core. Empo Player sends
// it in its own process, from PlayerLaunch.debugLogPath.
@_cdecl("gamecore_setDebugLogPath")
func ignoreCoreDebugLogPath(_ path: UnsafePointer<CChar>?) {}

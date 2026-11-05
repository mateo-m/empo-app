// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe
import UIKit

/// Bridge seam: registers mkxp callbacks, owns session-scoped services,
/// and forwards engine events to `EngineSessionCoordinatorDelegate`.
/// UI navigation (`phase`, `selectedGame`, alerts) stays on the delegate.
@MainActor
protocol EngineSessionCoordinatorDelegate: AnyObject {
    var coordinatorPhase: GamePhase? { get }
    var coordinatorEngineReady: Bool { get }
    var coordinatorSelectedGame: GameEntry? { get }
    var coordinatorActiveSessionGame: GameEntry? { get }

    func coordinatorFrameRendered()
    func coordinatorEngineTerminatedUnexpectedly(cleanExit: Bool)
    func coordinatorGameRectDidChange(_ rect: CGRect)
    func coordinatorDidReportEngineError(_ message: String)
    func coordinatorDidReportEngineInfo(_ message: String)
    func coordinatorEngineDidPause(snapshot: UIImage?)
    func coordinatorPausedGameStopped()
}

@MainActor
final class EngineSessionCoordinator {
    static let shared = EngineSessionCoordinator()

    weak var delegate: EngineSessionCoordinatorDelegate?

    private let crashTracker = CrashTracker()
    private let sessionLogger = SessionLogger()
    private var textInputModeHandler: ((Bool) -> Void)?
    /// The core `openCore` opened, or nil before it runs. The player
    /// UI reads this to hide a row the running core does not answer.
    private(set) var openedCore: (any GameCore)?
    /// Where the game of `openedCore` runs.
    private(set) var runner: GameRunner = .app
    let heldKeys = HeldKeys<KeyHolder>(send: { gamecore_injectKeyEvent($0, $1 ? 1 : 0) })

    var pendingCrashRecovery: Bool { crashTracker.pendingCrashRecovery }

    static var crashMessage: String {
        String(localized: "The game crashed last time. Your saves are safe. Open it again to keep playing.")
    }

    private init() {
        sessionLogger.onPlayTimeFlushed = { gameID in
            GameLibrary.shared.refreshGameEntry(id: gameID)
        }
        CABundleStore.refreshIfStale {
            EngineSessionCoordinator.shared.pushCABundlePath()
        }
        EmpoGameProcessClient.setEventHandler { text in
            Task { @MainActor in
                EngineSessionCoordinator.shared.note(text)
            }
        }
    }

    /// Adds a line to the log of the running session.
    func note(_ text: String) {
        sessionLogger.note(text)
    }

    /// Opens `core`, then pushes the launcher state into it.
    ///
    /// The folder picks the core (`GameCores.core(forGameAt:)`). Nothing
    /// is stored in the library entry, so a game imported before a core
    /// existed still picks the right one.
    ///
    /// A game whose core cannot kill its session runs in a new game
    /// process (`GameProcessHost`) when
    /// `AppSettings.rubyGameRunnerThisLaunch` says so. Then the app
    /// sends each `gamecore_*` call to it (`GameProcessClient.m`). Any
    /// other game runs in the app, in a core that the app opens. Every
    /// `gamecore_*` name resolves through a forwarder
    /// (`AppCoreForwarders.c`) that does one of the two. A call before
    /// a core opens in the app aborts, on purpose, because a silent
    /// no-op would hide it.
    ///
    /// A game starts only after `killSession` ended the one before it
    /// (`AppState.killPausedGame`).
    func openCore(_ core: any GameCore) {
        runner = core.canKillSession ? .app : AppSettings.rubyGameRunnerThisLaunch
        EmpoCoreUseGameProcess(runner == .gameProcess)
        switch runner {
        case .gameProcess:
            GameProcessHost.start(framework: core.framework)
        case .app:
            // AppState.selectGame refuses a game whose core this build
            // does not carry, so a failed open is a broken bundle or a
            // game that was not killed.
            guard let binary = core.binaryURL, EmpoCoreOpen(binary.path) != 0 else {
                fatalError("\(core.framework) cannot open. The log says why.")
            }
            if let openedCore, openedCore.framework == core.framework { return }
        }
        openedCore = core
        NSLog("[empo] core opened: %@", core.framework)

        // Game scripts see `$userAgent = "empo"`, `$empo = true`, and
        // `$userAgentVersion`, alongside the engine's JoiPlay-compat `$joiplay`.
        gamecore_setLauncherIdentity("empo", AppInfo.version)
        pushCABundlePath()
        AppSettings.shared.pushToCore()
        AppSettings.shared.pushSilentModeToCore()
        AppWindow.pushSafeAreaInsets()
        registerBridgeCallbacks()
    }

    /// TLS trust store for the engine's networking (native HTTP client
    /// plus Ruby openssl through SSL_CERT_FILE). Without it, TLS fails
    /// closed. Plain http still works. CABundleStore keeps the store
    /// refreshed silently. The native client re-reads the path on each
    /// request, so a refresh that lands mid-run applies to that side
    /// immediately, and Ruby picks it up next session.
    private func pushCABundlePath() {
        guard openedCore != nil else { return }
        if let caPath = CABundleStore.effectivePath {
            gamecore_setCABundlePath(caPath)
        } else {
            // Bundle assembly must have skipped the CA store. Catch it
            // in development. In release, fail closed (no TLS).
            assertionFailure("cacert.pem missing from Assets.bundle")
        }
    }

    /// Kills a paused or ended game, so that the next one can start.
    /// The pause or the end already recorded its play time.
    func killSession(of game: GameEntry?) {
        if let container = game?.container {
            crashTracker.removeMarker(for: container)
        }
        heldKeys.clear()
        switch runner {
        case .gameProcess: GameProcessHost.end()
        case .app: EmpoCoreKillSession()
        }
    }

    /// True when `killSession` can end the open game, so that another
    /// can start. A Ruby game in the app holds the app until it closes.
    var canEndGame: Bool {
        runner == .gameProcess || openedCore?.canKillSession == true
    }

    func consumeCrashRecovery() -> String? {
        guard crashTracker.pendingCrashRecovery else { return nil }
        crashTracker.consumeRecovery()
        return Self.crashMessage
    }

    func configureEngine(_ input: GameSession.LaunchInput) {
        openCore(input.core)
        GameSession.configureEngine(
            input,
            crashTracker: crashTracker,
            sessionLogger: sessionLogger
        )
    }

    /// Hands the engine its game path and starts it.
    ///
    /// The path goes in first. The core reads it as the first step of
    /// `gamecore_run_app`, so a path that is already set lets it run
    /// straight through.
    ///
    /// In the app, `RunLoop.main.perform`, not a main queue block.
    /// `EmpoCoreRunEngine` holds the main thread until the game ends,
    /// and a main queue block would stop that queue from draining for
    /// the whole session. The header on `EmpoCoreRunEngine` says what
    /// breaks.
    func launchGamePath(_ path: String) {
        gamecore_setGamePath(path)
        switch runner {
        case .gameProcess:
            _ = gamecore_run_app(0, nil)
        case .app:
            Task {
                // A game process ends a moment after `end`, and the
                // next game must not run beside it.
                await GameProcessHost.waitForExit()
                RunLoop.main.perform {
                    _ = EmpoCoreRunEngine()
                }
            }
        }
    }

    func requestPause() {
        gamecore_requestPause()
    }

    func requestResume() {
        gamecore_requestResume()
    }

    func recordSessionPlayTime(for game: GameEntry?) {
        sessionLogger.recordSessionPlayTime(for: game)
    }

    func resumeSessionTiming(for game: GameEntry?) {
        guard let game else { return }
        sessionLogger.resumeSessionTiming(for: game)
    }

    func clearCrashMarker(for container: GameContainer) {
        crashTracker.removeMarker(for: container)
    }

    func restoreCrashMarker(for container: GameContainer) {
        crashTracker.writeMarker(for: container)
    }

    func setTextInputModeHandler(_ handler: @escaping (Bool) -> Void) {
        textInputModeHandler = handler
    }

    func clearTextInputModeHandler() {
        textInputModeHandler = nil
    }

    // MARK: - Held keys

    func holdKey(scancode: Int32, by holder: KeyHolder) {
        heldKeys.hold(scancode, by: holder)
    }

    func releaseKey(scancode: Int32, by holder: KeyHolder) {
        heldKeys.release(scancode, by: holder)
    }

    /// Input paths call this when they lose the release edges: a
    /// controller unplugged, a remap screen opening, a session ending.
    func releaseKeys(from source: KeyHolder.Source) {
        heldKeys.release { $0.source == source }
    }

    func injectKey(scancode: Int32, pressed: Bool) {
        heldKeys.inject(scancode, pressed: pressed)
    }

    func injectKeyTap(scancode: Int32, holdMilliseconds: Int = 50) {
        heldKeys.tap(scancode, holdMilliseconds: holdMilliseconds)
    }

    private func registerBridgeCallbacks() {
        gamecore_setTextInputModeCallback(
            { active, _ in
                let on = active != 0
                Task { @MainActor in
                    EngineSessionCoordinator.shared.textInputModeHandler?(on)
                }
            }, nil)

        gamecore_setFrameRenderedCallback(
            { _ in
                Task { @MainActor in
                    EngineSessionCoordinator.shared.delegate?.coordinatorFrameRendered()
                }
            }, nil)

        gamecore_setEngineTerminatedCallback(
            { _ in
                Task { @MainActor in
                    EngineSessionCoordinator.shared.handleEngineTerminated()
                }
            }, nil)

        gamecore_setGameRectChangedCallback(
            { x, y, w, h, _ in
                let newRect = CGRect(
                    x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
                Task { @MainActor in
                    EngineSessionCoordinator.shared.delegate?
                        .coordinatorGameRectDidChange(newRect)
                }
            }, nil)

        gamecore_setErrorMessageCallback(
            { msg, _ in
                guard let msg else { return }
                let message = String(cString: msg)
                Task { @MainActor in
                    EngineSessionCoordinator.shared.delegate?
                        .coordinatorDidReportEngineError(message)
                    AppWindow.setAllowKeyWindow(true)
                }
            }, nil)

        gamecore_setInfoMessageCallback(
            { msg, _ in
                guard let msg else { return }
                let message = String(cString: msg)
                Task { @MainActor in
                    EngineSessionCoordinator.shared.delegate?
                        .coordinatorDidReportEngineInfo(message)
                    AppWindow.setAllowKeyWindow(true)
                }
            }, nil)

        gamecore_setPausedCallback(
            { _ in
                let snapshot = EngineSessionCoordinator.capturePauseSnapshot()
                Task { @MainActor in
                    EngineSessionCoordinator.shared.delegate?
                        .coordinatorEngineDidPause(snapshot: snapshot)
                }
            }, nil)

        gamecore_setResumedCallback({ _ in }, nil)
    }

    private func handleEngineTerminated() {
        recordSessionPlayTime(for: delegate?.coordinatorActiveSessionGame)
        if let container = delegate?.coordinatorSelectedGame?.container {
            crashTracker.removeMarker(for: container)
        }
        GameLibrary.shared.reload()

        // `killSession` does not report here. So every termination
        // comes from the game itself or from a crash of its process,
        // and both surface the alert. The system can also stop the
        // process of a paused game while Empo is in the background.
        if delegate?.coordinatorPhase != nil {
            let cleanExit = gamecore_didEngineExitCleanly() != 0
            note(cleanExit ? "The game closed itself." : "The game stopped.")
            delegate?.coordinatorEngineTerminatedUnexpectedly(cleanExit: cleanExit)
        } else if runner == .gameProcess {
            note("The game process of the paused game stopped.")
            delegate?.coordinatorPausedGameStopped()
        }
    }

    private static func capturePauseSnapshot() -> UIImage? {
        var w: Int32 = 0
        var h: Int32 = 0
        guard gamecore_getSnapshotSize(&w, &h), w > 0, h > 0 else { return nil }
        let totalBytes = Int(w) * Int(h) * 4
        var buffer = [UInt8](repeating: 0, count: totalBytes)
        guard gamecore_copySnapshotRGBA(&buffer, Int32(totalBytes), &w, &h) else { return nil }
        let data = Data(buffer)
        let bytesPerRow = Int(w) * 4
        guard let provider = CGDataProvider(data: data as CFData),
            let cgImage = CGImage(
                width: Int(w), height: Int(h),
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)
        else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

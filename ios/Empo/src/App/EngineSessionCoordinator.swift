import Foundation
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
    /// Per-scancode press start times. Light taps release before the
    /// RGSS thread observes a pressed-edge. We defer KEYUP until the
    /// key has been down for at least one frame (~16ms @ 60fps, with
    /// headroom). Same idea as `injectKeyTap(holdMilliseconds:)`.
    private var keyPressStartedAt: [Int32: ContinuousClock.Instant] = [:]
    private var pendingKeyReleases: [Int32: Task<Void, Never>] = [:]
    private static let minimumKeyHold: Duration = .milliseconds(50)
    /// Who currently holds each game key. Touch buttons, controller
    /// elements and keyboard keys all press the same small set of
    /// keys, so the engine may only see a release once the LAST
    /// holder lets go.
    private var keyHolders: [Int32: Set<KeyHolder>] = [:]

    var pendingCrashRecovery: Bool { crashTracker.pendingCrashRecovery }

    static let crashMessage =
        "The game crashed last time. Your saves are safe. "
        + "Open it again to keep playing."

    private init() {
        sessionLogger.onPlayTimeFlushed = { gameID in
            GameLibrary.shared.refreshGameEntry(id: gameID)
        }
        CABundleStore.refreshIfStale {
            EngineSessionCoordinator.shared.pushCABundlePath()
        }
    }

    /// Opens `core`, then pushes the launcher state into it.
    ///
    /// The folder picks the core (`GameCores.core(forGameAt:)`). Nothing
    /// is stored in the library entry, so a game imported before a core
    /// existed still picks the right one.
    ///
    /// Each game runs in a new game process (`GameProcessHost`), and
    /// the app sends each `gamecore_*` call to it
    /// (`GameProcessClient.m`). A game starts only after `killSession`
    /// ended the process of the one before it.
    func openCore(_ core: any GameCore) {
        GameProcessHost.start(framework: core.framework)
        openedCore = core
        NSLog("[empo] core opened: %@", core.framework)

        // Game scripts see `$userAgent = "empo"` and `$empo = true`,
        // alongside the engine's JoiPlay-compat `$joiplay`.
        gamecore_setLauncherIdentity("empo")
        pushCABundlePath()
        AppSettings.shared.pushToCore()
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
        clearPendingKeyHolds()
        GameProcessHost.end()
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

    /// Hands the engine its game path and starts it. The core reads
    /// the path as the first step of `gamecore_run_app`.
    func launchGamePath(_ path: String) {
        gamecore_setGamePath(path)
        _ = gamecore_run_app(0, nil)
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

    /// The engine sees a press when the first holder arrives. Holding
    /// twice with the same holder changes nothing.
    func holdKey(scancode: Int32, by holder: KeyHolder) {
        var holders = keyHolders[scancode] ?? []
        let wasEmpty = holders.isEmpty
        holders.insert(holder)
        keyHolders[scancode] = holders
        if wasEmpty {
            injectKey(scancode: scancode, pressed: true)
        }
    }

    /// The engine sees a release when the last holder lets go.
    func releaseKey(scancode: Int32, by holder: KeyHolder) {
        guard var holders = keyHolders[scancode], holders.remove(holder) != nil else { return }
        if holders.isEmpty {
            keyHolders.removeValue(forKey: scancode)
            injectKey(scancode: scancode, pressed: false)
        } else {
            keyHolders[scancode] = holders
        }
    }

    /// Drops every key one source holds. Input paths call this when
    /// they lose the release edges: a controller unplugged, a remap
    /// screen opening, a session ending.
    func releaseKeys(from source: KeyHolder.Source) {
        for (scancode, holders) in keyHolders {
            for holder in holders where holder.source == source {
                releaseKey(scancode: scancode, by: holder)
            }
        }
    }

    func injectKey(scancode: Int32, pressed: Bool) {
        if pressed {
            pendingKeyReleases.removeValue(forKey: scancode)?.cancel()
            keyPressStartedAt[scancode] = .now
            gamecore_injectKeyEvent(scancode, 1)
            return
        }

        pendingKeyReleases.removeValue(forKey: scancode)?.cancel()

        guard let started = keyPressStartedAt[scancode] else {
            gamecore_injectKeyEvent(scancode, 0)
            return
        }

        let held = ContinuousClock.now - started
        if held >= Self.minimumKeyHold {
            keyPressStartedAt.removeValue(forKey: scancode)
            gamecore_injectKeyEvent(scancode, 0)
            return
        }

        let remaining = Self.minimumKeyHold - held
        pendingKeyReleases[scancode] = Task { @MainActor in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            self.keyPressStartedAt.removeValue(forKey: scancode)
            self.pendingKeyReleases.removeValue(forKey: scancode)
            gamecore_injectKeyEvent(scancode, 0)
        }
    }

    func injectKeyTap(scancode: Int32, holdMilliseconds: Int = 50) {
        injectKey(scancode: scancode, pressed: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(holdMilliseconds))
            injectKey(scancode: scancode, pressed: false)
        }
    }

    private func clearPendingKeyHolds() {
        for task in pendingKeyReleases.values {
            task.cancel()
        }
        pendingKeyReleases.removeAll()
        for scancode in keyPressStartedAt.keys {
            gamecore_injectKeyEvent(scancode, 0)
        }
        keyPressStartedAt.removeAll()
        // A holder left behind would make the next session's first
        // press look like a second one, and the engine would never
        // see it.
        keyHolders.removeAll()
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
            delegate?.coordinatorEngineTerminatedUnexpectedly(cleanExit: cleanExit)
        } else {
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

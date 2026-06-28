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
    func coordinatorEngineDidPause(snapshot: UIImage?)
}

@MainActor
final class EngineSessionCoordinator {
    static let shared = EngineSessionCoordinator()

    weak var delegate: EngineSessionCoordinatorDelegate?

    private let crashTracker = CrashTracker()
    private let sessionLogger = SessionLogger()
    private let termination = EngineTerminationCoordinator()
    private var terminationExpected = false

    var pendingCrashRecovery: Bool { crashTracker.pendingCrashRecovery }

    static let crashMessage =
        "It looks like the game didn't exit cleanly last time. "
        + "Your save data should be fine."

    private init() {
        sessionLogger.onPlayTimeFlushed = { gameID in
            GameLibrary.shared.refreshGameEntry(id: gameID)
        }
        registerBridgeCallbacks()
    }

    func consumeCrashRecovery() -> String? {
        guard crashTracker.pendingCrashRecovery else { return nil }
        crashTracker.consumeRecovery()
        return Self.crashMessage
    }

    func configureEngine(_ input: GameSession.LaunchInput) {
        GameSession.configureEngine(
            input,
            crashTracker: crashTracker,
            sessionLogger: sessionLogger
        )
    }

    func launchGamePath(_ path: String) async {
        await termination.awaitEngineTermination()
        mkxp_setGamePath(path)
    }

    /// Returns whether the engine thread was still running before terminate.
    func beginReturnToLibrary(selectedContainer: GameContainer?) -> Bool {
        recordSessionPlayTime(for: delegate?.coordinatorActiveSessionGame)
        if let selectedContainer {
            crashTracker.removeMarker(for: selectedContainer)
        }

        let engineWasRunning = mkxp_isEngineTerminated() == 0
        if engineWasRunning {
            terminationExpected = true
            mkxp_requestTerminate()
        }
        return engineWasRunning
    }

    func armHangWatchdogIfNeeded(engineWasRunning: Bool, onHang: @escaping @MainActor (String) -> Void) {
        guard engineWasRunning else { return }
        termination.armHangWatchdog(onHang: onHang)
    }

    func requestPause() {
        mkxp_requestPause()
    }

    func requestResume() {
        mkxp_requestResume()
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

    private func registerBridgeCallbacks() {
        mkxp_setFrameRenderedCallback(
            { _ in
                Task { @MainActor in
                    EngineSessionCoordinator.shared.delegate?.coordinatorFrameRendered()
                }
            }, nil)

        mkxp_setEngineTerminatedCallback(
            { _ in
                Task { @MainActor in
                    EngineSessionCoordinator.shared.handleEngineTerminated()
                }
            }, nil)

        mkxp_setGameRectChangedCallback(
            { x, y, w, h, _ in
                let newRect = CGRect(
                    x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
                Task { @MainActor in
                    EngineSessionCoordinator.shared.delegate?
                        .coordinatorGameRectDidChange(newRect)
                }
            }, nil)

        mkxp_setErrorMessageCallback(
            { msg, _ in
                guard let msg else { return }
                let message = String(cString: msg)
                Task { @MainActor in
                    EngineSessionCoordinator.shared.delegate?
                        .coordinatorDidReportEngineError(message)
                    AppWindow.setAllowKeyWindow(true)
                }
            }, nil)

        mkxp_setPausedCallback(
            { _ in
                let snapshot = EngineSessionCoordinator.capturePauseSnapshot()
                Task { @MainActor in
                    EngineSessionCoordinator.shared.delegate?
                        .coordinatorEngineDidPause(snapshot: snapshot)
                }
            }, nil)

        mkxp_setResumedCallback({ _ in }, nil)
    }

    private func handleEngineTerminated() {
        termination.handleEngineTerminatedAck()
        recordSessionPlayTime(for: delegate?.coordinatorActiveSessionGame)
        if let container = delegate?.coordinatorSelectedGame?.container {
            crashTracker.removeMarker(for: container)
        }
        GameLibrary.shared.reload()

        let phase = delegate?.coordinatorPhase
        if !terminationExpected && phase != nil {
            let cleanExit = mkxp_didEngineExitCleanly() != 0
            delegate?.coordinatorEngineTerminatedUnexpectedly(cleanExit: cleanExit)
        }
        terminationExpected = false
    }

    private static func capturePauseSnapshot() -> UIImage? {
        var w: Int32 = 0
        var h: Int32 = 0
        guard mkxp_getSnapshotSize(&w, &h), w > 0, h > 0 else { return nil }
        let totalBytes = Int(w) * Int(h) * 4
        var buffer = [UInt8](repeating: 0, count: totalBytes)
        guard mkxp_copySnapshotRGBA(&buffer, Int32(totalBytes), &w, &h) else { return nil }
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

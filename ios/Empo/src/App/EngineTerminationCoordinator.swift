import Foundation

/// Coordinates RGSS engine-thread termination handshakes.
/// `selectGame` then does not race new sessions against sessions
/// that still terminate. Also surfaces a hang dialog (or
/// force-quits) when the engine never acks.
///
/// Usage pattern:
/// - `returnToLibrary()` calls `armHangWatchdog { msg in state.errorMessage = msg }`.
/// - The bridge's engine-terminated callback calls `handleEngineTerminatedAck()` to cancel the watchdog and drain any pending `selectGame` awaiter.
/// - `selectGame` calls `awaitEngineTermination()` before handing the new game path to the RGSS thread.
@MainActor
final class EngineTerminationCoordinator {
    static let hangMessage =
        "The previous game stopped responding. The app will now close."

    private static let hangWatchdogSeconds: UInt64 = 3

    // When returnToLibrary() asks the engine to terminate, this arms a
    // watchdog that fires after a few seconds. If the engine-terminated
    // callback clears this token by then, the RGSS thread acked cleanly
    // and there is nothing to do. Otherwise the RGSS thread is stuck
    // and the hang alert surfaces immediately. We do not wait for
    // main.cpp's 10s timeout, which would fire on the NEXT session's
    // Loading view and confuse the user.
    private var pendingToken: UUID?

    // Continuations that wait for the engine-terminated callback.
    // selectGame() uses them to wait for cross-session teardown before
    // it hands the engine a new path. handleEngineTerminatedAck drains
    // them when the callback runs. No polling, no timeouts. The hang
    // watchdog above handles the truly-stuck case: it force-quits the
    // app, which also drains these implicitly (the process exits).
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func awaitEngineTermination() async {
        // Fast path: the engine is already terminated (the previous
        // session finished its cross-session cleanup and now parks in
        // waitForGamePath). Hand off immediately.
        if mkxp_isEngineTerminated() != 0 { return }
        // No termination is in flight. This is a cold boot, and the
        // RGSS thread waits for its FIRST game path. Hand off
        // immediately without a park.
        if pendingToken == nil { return }
        // A termination is actively in flight. Park until the
        // engine-terminated callback drains the continuation.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    /// The bridge's engine-terminated callback calls this. It cancels
    /// any armed watchdog and wakes selectGame awaiters. The pending
    /// new session can then hand its path to the RGSS thread.
    func handleEngineTerminatedAck() {
        pendingToken = nil
        let pending = waiters
        waiters.removeAll()
        for cont in pending { cont.resume() }
    }

    /// Arms a one-shot timer. If the engine did not ack termination
    /// within `hangWatchdogSeconds`, invoke `onHang` with a user-facing
    /// message and mark the bridge as hung.
    func armHangWatchdog(onHang: @escaping @MainActor (String) -> Void) {
        let token = UUID()
        pendingToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.hangWatchdogSeconds * 1_000_000_000)
            guard let self, self.pendingToken == token else { return }
            self.pendingToken = nil
            mkxp_setEngineHung()
            onHang(Self.hangMessage)
        }
    }

    // armLoadingEscapeForceQuit removed 2026-05-02. It terminated
    // the process after a 5s deadline as a hard escape from a hung
    // loading screen. App Store guideline 2.5.1 forbids
    // self-termination. A static "close from app switcher" label
    // replaced the loading-view button that armed this, when we
    // disabled all cross-session quit paths (see
    // docs/multi-session.md).
}

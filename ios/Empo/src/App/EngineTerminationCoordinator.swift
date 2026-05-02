import Foundation

/// Coordinates RGSS engine-thread termination handshakes so `selectGame`
/// doesn't race new sessions against still-terminating ones, and surfaces
/// a hang dialog (or force-quits) when the engine never ack's.
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
    // callback clears this token by then, the RGSS thread ack'd cleanly
    // and there's nothing to do. Otherwise the RGSS thread is stuck and
    // the hang alert surfaces immediately — without waiting for
    // main.cpp's 10s timeout, which would otherwise fire on the NEXT
    // session's Loading view and confuse the user.
    private var pendingToken: UUID?

    // Continuations waiting for the engine-terminated callback to fire,
    // used by selectGame() to wait for cross-session teardown before
    // handing the engine a new path. Drained in handleEngineTerminatedAck
    // when the callback runs. No polling, no timeouts — the hang
    // watchdog above handles the truly-stuck case by force-quitting
    // the app, which also implicitly drains these (the process exits).
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func awaitEngineTermination() async {
        // Fast path: engine is already terminated (previous session
        // finished its cross-session cleanup and is parked in
        // waitForGamePath) — hand off immediately.
        if mkxp_isEngineTerminated() != 0 { return }
        // No termination is in flight — this is a cold boot, the RGSS
        // thread is waiting for its FIRST game path. Hand off
        // immediately without parking.
        if pendingToken == nil { return }
        // A termination is actively in flight. Park until the
        // engine-terminated callback drains the continuation.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    /// Called by the bridge's engine-terminated callback. Cancels any
    /// armed watchdog and wakes selectGame awaiters so the pending new
    /// session can hand its path to the RGSS thread.
    func handleEngineTerminatedAck() {
        pendingToken = nil
        let pending = waiters
        waiters.removeAll()
        for cont in pending { cont.resume() }
    }

    /// Arms a one-shot timer: if the engine hasn't ack'd termination
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

    // armLoadingEscapeForceQuit removed 2026-05-02. It used to
    // programmatically terminate the process after a 5s deadline
    // as a hard escape from a hung loading screen. App Store
    // guideline 2.5.1 forbids self-termination, and the
    // loading-view button that armed this was replaced with a
    // static "close from app switcher" label as part of disabling
    // all cross-session quit paths (see QUIT_PATHS_DISABLED.md).
}

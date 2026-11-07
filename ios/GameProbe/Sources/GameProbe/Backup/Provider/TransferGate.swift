import Foundation

/// The wait a provider makes when a service asks it to slow down.
///
/// It is a protocol so a test can honor `Retry-After` with a fake
/// clock and no real sleep.
public protocol BackupClock: Sendable {
    func wait(seconds: TimeInterval) async
}

/// The clock the app runs on.
public struct SystemBackupClock: BackupClock {

    public init() {}

    public func wait(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// The in-flight limit and the throttle wait of SPEC 8.6.
///
/// The gate does two jobs, and they do not cover the same calls:
///
/// - Four transfers per target at a time. A transfer is a `put` or
///   a `get`, because those are the two operations that move a
///   file. Use `transfer`.
/// - `Retry-After` on every call the service can throttle, which is
///   every call it answers. `list`, `delete`, and `quota` move no
///   file, so they take no slot. Use `request`.
///
/// Every provider owns one gate. **Put the whole operation inside
/// the body, both phases of a `put`.** The commit is a request of
/// its own on Dropbox and on Google Drive, and it answers 429 like
/// any other, so a commit outside the gate would pass a throttle to
/// the engine that the provider must honor itself.
///
/// A call that is still throttled after `attempts` tries throws
/// `throttled` to the engine, which waits the stated time and keeps
/// the run, per 8.4.
///
/// Retrying a `put` costs the bytes again. That is the price 8.1
/// states when it keeps resumability inside the provider.
public actor TransferGate {

    /// The fixed limit of 8.6.
    public static let maxInFlight = 4

    private let limit: Int
    private let attempts: Int
    private let clock: BackupClock

    private var inFlight = 0
    /// The transfers that wait for a slot, first in first out. The
    /// answer is false for a waiter that was cancelled.
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    public init(
        limit: Int = TransferGate.maxInFlight,
        attempts: Int = 3,
        clock: BackupClock = SystemBackupClock()
    ) {
        self.limit = max(1, limit)
        self.attempts = max(1, attempts)
        self.clock = clock
    }

    /// Runs one `put` or one `get`. It takes a slot and it honors
    /// `Retry-After`.
    public func transfer<T: Sendable>(
        _ body: @Sendable () async throws(BackupProviderError) -> T
    ) async throws(BackupProviderError) -> T {
        try await honorThrottle(takesSlot: true, body)
    }

    /// Runs one call that moves no file: `list`, `delete`, or
    /// `quota`. It honors `Retry-After` and it takes no slot,
    /// because the limit of 8.6 counts transfers.
    public func request<T: Sendable>(
        _ body: @Sendable () async throws(BackupProviderError) -> T
    ) async throws(BackupProviderError) -> T {
        try await honorThrottle(takesSlot: false, body)
    }

    private func honorThrottle<T: Sendable>(
        takesSlot: Bool,
        _ body: @Sendable () async throws(BackupProviderError) -> T
    ) async throws(BackupProviderError) -> T {
        var attempt = 1
        while true {
            // The engine reads the cancel from the task and stops the
            // run as paused, whatever error the call throws.
            if takesSlot, !(await acquire()) { throw BackupProviderError.offline }
            do {
                let value = try await body()
                if takesSlot { release() }
                return value
            } catch {
                // The slot goes back before the wait. A throttled
                // transfer that held its slot would cut the target
                // to three.
                if takesSlot { release() }
                guard case .throttled(let retryAfter) = error, attempt < attempts else {
                    throw error
                }
                attempt += 1
                await clock.wait(seconds: retryAfter)
            }
        }
    }

    // MARK: - The slot

    /// Answers false, with no slot, when the task is cancelled while
    /// it waits.
    private func acquire() async -> Bool {
        if inFlight < limit {
            inFlight += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.dropWaiter(id) }
        }
        // A true answer came from `release`, which handed its slot
        // over rather than giving it up. Counting it again here would
        // let a fifth transfer in between the two steps.
    }

    /// A waiter that `release` already woke holds its slot, and its
    /// own release gives the slot back.
    private func dropWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}

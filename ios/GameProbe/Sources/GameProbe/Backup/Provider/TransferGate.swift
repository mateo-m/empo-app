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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// The most transfers this gate ever held at one time.
    public private(set) var peakInFlight = 0
    /// Every wait this gate made, in seconds and in order.
    public private(set) var waitedSeconds: [TimeInterval] = []

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
            if takesSlot { await acquire() }
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
                waitedSeconds.append(retryAfter)
                await clock.wait(seconds: retryAfter)
            }
        }
    }

    // MARK: - The slot

    private func acquire() async {
        if inFlight < limit {
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        // The slot came from `release`, which handed it over rather
        // than giving it up. Counting it again here would let a
        // fifth transfer in between the two steps.
    }

    private func release() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Holds transfers open so a test can see several of them in flight
/// at one time.
///
/// It is here and not in the tests because `FakeBackupTarget` awaits
/// it inside the transfer body, and both the gate check and the fake
/// target check need it.
public actor TransferLatch {

    private var isOpen: Bool
    /// How many transfers pass before the latch starts to hold. The
    /// default holds the first one. A test that has to stop a run at
    /// a later call raises it.
    private let holdFrom: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many transfers reached the latch.
    public private(set) var arrivedCount = 0

    public init(open: Bool = false, holdFrom: Int = 1) {
        self.isOpen = open
        self.holdFrom = max(1, holdFrom)
    }

    public func wait() async {
        arrivedCount += 1
        guard !isOpen, arrivedCount >= holdFrom else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Lets every waiting transfer through, and every later one.
    public func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume() }
    }

    /// Waits until `count` transfers reach the latch, or until the
    /// yield budget runs out. Returns whether the count arrived.
    public func waitForArrivals(_ count: Int, yields: Int = 10_000) async -> Bool {
        var left = yields
        while arrivedCount < count, left > 0 {
            left -= 1
            await Task.yield()
        }
        return arrivedCount >= count
    }
}

import Foundation

/// Holds transfers open so a test can see several of them in flight
/// at one time.
actor TransferLatch {

    private var isOpen: Bool
    /// How many transfers pass before the latch starts to hold. The
    /// default holds the first one. A test that has to stop a run at
    /// a later call raises it.
    private let holdFrom: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] =
        [:]

    /// How many transfers reached the latch.
    private(set) var arrivedCount = 0

    init(open: Bool = false, holdFrom: Int = 1) {
        self.isOpen = open
        self.holdFrom = max(1, holdFrom)
    }

    func wait() async {
        arrivedCount += 1
        for (id, waiter) in arrivalWaiters where waiter.count <= arrivedCount {
            resumeArrival(id, with: true)
        }
        guard !isOpen, arrivedCount >= holdFrom else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Lets every waiting transfer through, and every later one.
    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume() }
    }

    /// Waits until `count` transfers reach the latch. Returns false
    /// only when `timeoutNanoseconds` passes first.
    func waitForArrivals(_ count: Int, timeoutNanoseconds: UInt64 = 30_000_000_000) async -> Bool {
        guard arrivedCount < count else { return true }
        let id = UUID()
        let timer = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            self.resumeArrival(id, with: false)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { arrivalWaiters[id] = (count, $0) }
    }

    private func resumeArrival(_ id: UUID, with arrived: Bool) {
        arrivalWaiters.removeValue(forKey: id)?.continuation.resume(returning: arrived)
    }
}

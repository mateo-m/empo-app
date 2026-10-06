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

    /// How many transfers reached the latch.
    private(set) var arrivedCount = 0

    init(open: Bool = false, holdFrom: Int = 1) {
        self.isOpen = open
        self.holdFrom = max(1, holdFrom)
    }

    func wait() async {
        arrivedCount += 1
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

    /// Waits until `count` transfers reach the latch, or until the
    /// yield budget runs out. Returns whether the count arrived.
    func waitForArrivals(_ count: Int, yields: Int = 10_000) async -> Bool {
        var left = yields
        while arrivedCount < count, left > 0 {
            left -= 1
            await Task.yield()
        }
        return arrivedCount >= count
    }
}

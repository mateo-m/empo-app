import Foundation
import GameProbe
import UIKit

/// When the replication pass of SPEC 10.5 runs, per 10.11.
///
/// `SyncEngine` holds the six steps. This holds the two triggers,
/// the wait a local change takes, and the one pass that follows
/// another.
@MainActor
final class SyncPass {

    static let shared = SyncPass()

    /// What the pass is doing.
    private enum State {
        /// `start()` has not run, so no news reaches the pass yet.
        case new
        case idle
        /// A pass is due, and the task waits for it.
        case waiting(Task<Void, Never>)
        /// A pass is in flight. News that arrives now asks for the
        /// pass that follows it.
        case running(newsArrived: Bool)
    }

    private var state = State.new
    private var engine: SyncEngine?

    // MARK: - The two triggers of 10.11

    /// The scene delegate calls this once.
    func start() {
        guard case .new = state else { return }
        state = .idle
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SyncPass.shared.schedule(.now) }
        }
        center.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SyncPass.shared.schedule(.afterALocalChange) }
        }
        center.addObserver(
            forName: .layoutProfileDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SyncPass.shared.schedule(.afterALocalChange) }
        }
        SyncDeviceCheck.run()
        schedule(.now)
    }

    /// How long a local change waits, because a settings screen
    /// writes a key on every keystroke and every drag.
    static let localChangeWait: Double = 15

    /// The pass this device asks for next. A second ask inside the
    /// wait replaces the first.
    func schedule(_ trigger: SyncTrigger) {
        // A play session writes preferences of its own, and it does
        // not ask for a pass.
        if case .afterALocalChange = trigger, BackupDeviceConditions.isSessionLive { return }
        switch state {
        case .new:
            return
        case .running:
            state = .running(newsArrived: true)
        case .waiting(let task):
            task.cancel()
            state = .waiting(waitThenRun(trigger))
        case .idle:
            state = .waiting(waitThenRun(trigger))
        }
    }

    private func waitThenRun(_ trigger: SyncTrigger) -> Task<Void, Never> {
        Task { [weak self] in
            if case .afterALocalChange = trigger {
                try? await Task.sleep(for: .seconds(Self.localChangeWait))
            }
            guard !Task.isCancelled else { return }
            await self?.run(trigger)
        }
    }

    /// One pass. It answers nothing, because the user never waits
    /// for it, per 10.11.
    func run(_ trigger: SyncTrigger = .now) async {
        if case .running = state {
            // The news that asked for this pass arrived after the
            // running one read the targets, so it runs again after.
            state = .running(newsArrived: true)
            return
        }
        state = .running(newsArrived: false)
        defer { runTheNextPass() }

        guard let engine = engine ?? makeTheEngine() else { return }
        switch await engine.run(trigger) {
        case .runAgain:
            state = .running(newsArrived: true)
        case .failed(let reason):
            log(reason)
        case .done, .nothingToDo, .noLocalNews:
            break
        }
    }

    /// The pass that follows, where news arrived while this one ran.
    private func runTheNextPass() {
        guard case .running(let newsArrived) = state else { return }
        state = .idle
        if newsArrived { schedule(.now) }
    }

    private func makeTheEngine() -> SyncEngine? {
        guard let namespaceId = try? BackupKeychain.namespaceId() else { return nil }
        let engine = SyncEngine(
            document: AutomergeDocumentStore(),
            targets: ProviderSyncTargets(),
            state: SyncFileStore(),
            local: DeviceSyncValues(),
            device: DeviceRecord(
                deviceId: BackupDevice.id, model: BackupDevice.model, name: BackupDevice.name,
                lastWriteAt: Date()),
            namespaceId: namespaceId,
            now: { Date() },
            didMerge: { SyncDeviceCheck.dump($0, heads: $1) },
            note: { [weak self] in self?.log($0) })
        self.engine = engine
        return engine
    }

    private func log(_ message: String) {
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("SyncPass", message)
    }
}

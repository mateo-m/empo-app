import Foundation
import GameProbe
import UIKit

/// What one backup pass does.
///
/// The scheduler owns when a pass runs. It owns nothing about what a
/// pass does, because that needs a provider and ticket 008 brings the
/// first one. Until a runner registers, every trigger does its gate
/// work and stops.
@MainActor
protocol BackupRunning: AnyObject {
    /// Runs one pass.
    ///
    /// `progress` belongs to a continued-processing task, which must
    /// report progress or the system expires it. The pass must check
    /// `Task.isCancelled` at every file boundary, per 7.6.
    func runBackup(
        scope: BackupScanScope, trigger: BackupTrigger, progress: Progress?
    ) async -> BackupPassResult
}

/// What a pass reports back to the scheduler.
struct BackupPassResult: Sendable {
    /// True when the pass did all the work it planned.
    var didFinish: Bool
    /// One row for each target the pass touched.
    var targets: [BackupPassTarget]

    init(didFinish: Bool = false, targets: [BackupPassTarget] = []) {
        self.didFinish = didFinish
        self.targets = targets
    }
}

/// One target as a pass left it. A target with no cause re-arms its
/// notifications, per 7.11, so a clean target still belongs here.
struct BackupPassTarget: Sendable {
    var id: String
    var label: String
    var causes: Set<BackupFailFastCause>

    init(id: String, label: String, causes: Set<BackupFailFastCause> = []) {
        self.id = id
        self.label = label
        self.causes = causes
    }
}

/// The one place that decides when a backup run starts, per SPEC 7.
///
/// The rules it applies are pure and live in GameProbe. This file
/// holds what only iOS answers: the app lifetime, the background
/// grant, the device conditions, and the two background tasks.
@MainActor
final class BackupScheduler {

    static let shared = BackupScheduler()

    private init() {}

    /// What one pass does. Ticket 008 set it to `BackupPass`.
    var runner: (any BackupRunning)?

    /// The network cause the stale line carries, per 7.4. It is
    /// `waitingForWiFi` while the switch is off and the device is on
    /// cellular.
    private(set) var networkCause: StaleCause?

    /// The written detail of a run the process did not survive.
    static let interruptedDetail = "the run stopped when Empo closed"

    private var didStart = false
    /// Whether a pass is in flight. The manual restore door of
    /// 11.3 closes while one is, per the third row of that section.
    private(set) var isRunning = false
    private var foregroundWait: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private lazy var store: BackupStateStore? = try? BackupRoot.openStateStore()

    // MARK: - Launch

    /// Starts the schedule. The scene delegate calls this once.
    ///
    /// `BackupTaskScheduler.register()` is not here. iOS wants every
    /// launch handler in place before launch ends, so the app
    /// delegate calls it earlier.
    func start() {
        guard !didStart else { return }
        didStart = true

        BackupRoot.prepare()
        BackupNetwork.start()
        BackupTransferSession.shared.start()
        ICloudDriveGate.shared.start()
        runner = BackupPass.shared
        observeAppLifetime()
        BackupTaskScheduler.scheduleNightly()
        countTheRunsThatVanished()
        log("the schedule started")
        BackupDeviceCheck.run()
    }

    private func observeAppLifetime() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BackupScheduler.shared.appDidEnterBackground() }
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BackupScheduler.shared.appDidBecomeActive() }
        }
    }

    // MARK: - The backbone

    /// Runs the backbone pass as the app goes to the background.
    ///
    /// A live session stops it, per 7.6. A background pause keeps the
    /// player view mounted, so a paused session still counts as live
    /// and backgrounding during play is not session end.
    private func appDidEnterBackground() {
        foregroundWait?.cancel()
        foregroundWait = nil
        guard !BackupDeviceConditions.isSessionLive else { return }
        Task { await runUnderTheGrant(.sessionEndOrBackground) }
    }

    /// The other half of the backbone. `AppState` calls it once the
    /// engine terminates and the session is over.
    func playSessionDidEnd(game: GameEntry?) {
        if let container = game?.container {
            markDirty(container: container, reason: "play session")
        }
        Task { await runUnderTheGrant(.sessionEndOrBackground) }
    }

    /// Marks a game for the next backbone pass, which scans dirty
    /// games alone.
    func markDirty(container: GameContainer, reason: String) {
        let gameKey = BackupKeys.gameKey(containerFolderName: container.folderName)
        try? store?.markDirty(gameKey: gameKey, reason: reason, at: Date())
    }

    private func runUnderTheGrant(_ trigger: BackupTrigger) async {
        await BackupBackgroundTask.run(named: "backup.\(trigger.rawValue)") {
            await BackupScheduler.shared.run(trigger: trigger)
            await BackupBackgroundTask.holdForADeviceCheck()
        }
    }

    // MARK: - The catch-up pass

    /// Starts the 30-second wait of 7.3. Launching Empo and tapping
    /// into a game scans nothing, because the wait never ends.
    private func appDidBecomeActive() {
        guard foregroundWait == nil, !BackupDeviceConditions.isSessionLive else { return }
        foregroundWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(BackupTriggerPlan.foregroundDelay))
            guard !Task.isCancelled else { return }
            self?.foregroundWait = nil
            await self?.run(trigger: .foreground)
        }
    }

    // MARK: - The manual button

    /// "Back up now", from the Backup sheet of one game or from the
    /// Backups screen. There is no third entry point, per 13.11.
    func pressBackUpNow(_ press: ManualBackupPress) {
        guard !BackupTaskScheduler.submitManual(press) else { return }
        // The system refused the task, so the pass runs in the
        // foreground and hands its uploads to the background session.
        runTask = Task { await run(trigger: .manual, press: press) }
    }

    /// Pause, from the run block of 13.4 or the Backup sheet of
    /// 13.15.
    ///
    /// The engine reads `Task.isCancelled` at every file boundary,
    /// per 7.6, so a cancel leaves whole files behind and the
    /// checkpoint of 6.5 carries the rest to the next run.
    func pauseTheRun() {
        runTask?.cancel()
        runTask = nil
        recordThePause()
    }

    // MARK: - The resume question of 6.5 and 13.18

    /// A pause is its own record. It keeps the staging and the outbox
    /// files, and it never asks at the next launch, because resume is
    /// one tap while the process lives.
    private func recordThePause() {
        guard let store, var record = try? store.intent(kind: .interruptedRun) else {
            return
        }
        record.kind = .pausedRun
        try? store.saveIntent(record)
    }

    /// The run the process did not survive, or `nil` when the last
    /// launch left nothing to ask about.
    func pendingResume() -> BackupIntentRecord? {
        guard let store else { return nil }
        let record = try? store.intent(kind: .interruptedRun)
        return BackupResumeQuestion.asks(record) ? record : nil
    }

    /// Applies one answer to the resume question.
    ///
    /// Every answer marks the record asked, because the question was
    /// asked. That is what keeps one interruption from asking twice.
    func answerResume(_ action: BackupResumeQuestion.Action, gameName: String) {
        guard let store else { return }
        let record = try? store.intent(kind: .interruptedRun)
        try? store.markIntentAsked(kind: .interruptedRun)

        let effect = BackupResumeQuestion.effect(of: action)
        if effect.startsRunNow, let gameKey = record?.gameKey {
            pressBackUpNow(.game(gameKey: gameKey, gameName: gameName))
        }
        guard !effect.keepsRecord else { return }
        try? store.clearIntent(kind: .interruptedRun)
        if effect.cleansStagingAndOutbox { Self.cleanStagingAndOutbox() }
    }

    /// Stop backup throws the staged copies and the outbox away. The
    /// blobs the target already confirmed stay where they are,
    /// because the store is content addressed.
    private static func cleanStagingAndOutbox() {
        let fm = FileManager.default
        for directory in [BackupRoot.layout.staging, BackupRoot.layout.outbox] {
            for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    // MARK: - One pass

    /// Applies the gates of 7.4, 7.5, and 7.6, then hands the pass to
    /// the runner.
    @discardableResult
    func run(
        trigger: BackupTrigger,
        press: ManualBackupPress? = nil,
        progress: Progress? = nil
    ) async -> Bool {
        guard !isRunning else { return false }

        let conditions = BackupDeviceConditions.now(isManual: trigger == .manual)
        switch ResourcePolicy.stagingGate(conditions) {
        case .pause(let reason):
            BackupRunMonitor.shared.pause = reason
            log("%@ paused: %@", trigger.rawValue, reason.line)
            close(progress)
            return false
        case .run:
            BackupRunMonitor.shared.pause = nil
        }

        // The uploads wait inside the transfer daemon, and the stale
        // line says what they wait for. Staging still runs, because
        // the clock of 7.1 runs while Empo's own policy blocks the
        // run.
        networkCause = ResourcePolicy.blockedCause(
            policy: BackupNetwork.policy, isOnCellular: BackupNetwork.isOnCellular)

        log(
            "%@ runs, network %@",
            trigger.rawValue, networkCause == nil ? "clear" : BackupNetwork.waitingLine)

        guard let runner else {
            // Ticket 008 brings the first provider. Until then the
            // gates run and the pass stops here.
            log("%@ has no runner yet", trigger.rawValue)
            close(progress)
            return false
        }

        isRunning = true
        BackupBadges.shared.invalidate()
        defer {
            isRunning = false
            BackupNetwork.allowsThisRunOverCellular = false
            BackupBadges.shared.invalidate()
        }
        progress?.totalUnitCount = 1

        let result = await runner.runBackup(
            scope: BackupTriggerPlan.scope(of: trigger, press: press),
            trigger: trigger,
            progress: progress)

        close(progress)
        record(result.didFinish ? .succeeded : .otherFailure)
        report(result.targets)
        return result.didFinish
    }

    /// The one line a device check reads. The Backups screen of
    /// ticket 016 shows the same state on screen.
    private func log(_ format: String, _ arguments: CVarArg...) {
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("BackupScheduler", String(format: format, arguments: arguments))
    }

    /// A continued-processing task that stops reporting progress is
    /// expired by the system, so every exit closes it.
    private func close(_ progress: Progress?) {
        guard let progress else { return }
        progress.totalUnitCount = max(progress.totalUnitCount, 1)
        progress.completedUnitCount = progress.totalUnitCount
    }

    // MARK: - Force quit

    /// Counts the runs that vanished with the process, per 7.10.
    ///
    /// Empo cannot see a force quit. What it sees at launch is a run
    /// row that never finished while the background session carries
    /// no task for it. The foreground pass then restarts the work.
    private func countTheRunsThatVanished() {
        Task { [weak self] in
            let live = await BackupTransferSession.shared.liveTaskPaths()
            // The daemon still carries the run, so the process death
            // cost nothing.
            guard live.isEmpty else { return }
            self?.closeTheRunsThatVanished()
        }
    }

    private func closeTheRunsThatVanished() {
        guard let store else { return }
        let open = ((try? store.runHistory()) ?? []).filter { $0.finishedAt == nil }
        guard !open.isEmpty else { return }

        // One launch counts one interrupted run, however many targets
        // the run covered.
        record(.interrupted)

        let now = Date()
        for var row in open {
            row.finishedAt = now
            row.detail = Self.interruptedDetail
            try? store.recordRun(row)
        }
    }

    private func record(_ ending: InterruptedRunEnding) {
        guard let store, let tally = try? store.interruptedRunTally() else { return }
        try? store.saveInterruptedRunTally(tally.recording(ending))
    }

    // MARK: - The three notifications

    /// Reports every target the pass touched, per 7.11. A target with
    /// no cause re-arms, so a clean target must come through here.
    private func report(_ targets: [BackupPassTarget]) {
        guard let store else { return }
        for target in targets {
            BackupNotifier.report(
                causes: target.causes,
                targetId: target.id,
                targetLabel: target.label,
                store: store)
        }
    }
}

import Foundation
import GameProbe

/// What the run in flight shows on screen, per SPEC 13.2 and 13.3.
///
/// The engine freezes the run plan and reports it here. The pill,
/// the card badge, the run block, and the Backup sheet header all
/// read this one plan, so no screen computes a second one.
@MainActor
@Observable
final class BackupRunMonitor: BackupRunObserver {

    static let shared = BackupRunMonitor()

    private init() {}

    private(set) var plan = BackupRunPlan()
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    /// The games the pass covers, in the order the run takes them,
    /// with the name each card shows.
    private(set) var queue: [BackupRunGameRow] = []
    /// The games the pass in flight covers, per 13.17. A game in
    /// this set locks what writes its container.
    private(set) var runningGameKeys: Set<String> = []
    /// Why staging is not running, per 7.5 and 7.6, or `nil` while
    /// nothing holds it. The scheduler writes it at each gate.
    var pause: StagingPause?
    /// Why the system holds the uploads, per 7.4, or `nil` while they
    /// move. The path monitor writes it on every change.
    var networkHold: String?
    /// The cause the pass stopped on, in the words of the notice, or
    /// `nil` while every target finished.
    var stopLine: String?
    /// The stream the engine stages now, or `nil` between streams.
    private var stagingKey: String?
    /// The clock the pill's own 2-second and 5-second rules read.
    /// A timer moves it, because neither rule reacts to an event.
    private(set) var now = Date()

    private var namesByKey: [String: String] = [:]
    private var ticker: Task<Void, Never>?
    /// The progress of the continued-processing task of 7.3. The
    /// system expires a task whose progress stands still, so every
    /// confirmed blob moves it, not only a finished target.
    private var progress: Progress?
    private var targetCount = 0
    private var targetsDone = 0
    /// What the plan had confirmed when the target in flight began.
    private var confirmedBeforeThisTarget: Int64 = 0
    /// The bytes sent of the one upload in flight. A 300 MB blob
    /// confirms nothing for a minute, and the pill must still move.
    private var inFlightBytes: Int64 = 0

    // MARK: - What the pass reports

    /// The pass starts and names what it covers.
    func runStarts(names: [String: String], progress: Progress? = nil, targetCount: Int = 0) {
        namesByKey = names
        self.progress = progress
        self.targetCount = targetCount
        targetsDone = 0
        confirmedBeforeThisTarget = 0
        runningGameKeys = Set(names.keys)
        plan = BackupRunPlan()
        startedAt = Date()
        finishedAt = nil
        stopLine = nil
        stagingKey = nil
        networkHold = BackupNetwork.holdLine
        now = Date()
        queue =
            names
            .map { BackupRunGameRow(gameKey: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
        startTheTicker()
    }

    func targetEnds() {
        targetsDone += 1
        confirmedBeforeThisTarget = plan.confirmedBytes
        inFlightBytes = 0
        report()
    }

    /// Bytes that move prove the system holds nothing, whatever the
    /// path monitor last said. The phone reported an expensive path
    /// after a launch from the lock screen and never took it back.
    func transferSent(bytes: Int64) {
        inFlightBytes = bytes
        networkHold = nil
        report()
    }

    func runEnds() {
        // A cancelled run did not complete, so the pill hides instead
        // of saying "Backup complete".
        if Task.isCancelled { startedAt = nil } else { finishedAt = Date() }
        now = Date()
        runningGameKeys = []
        progress = nil
    }

    nonisolated func runStages(streamKey: String) async {
        await MainActor.run { stagingKey = streamKey }
    }

    nonisolated func runPlanned(streamKey: String, bytes: Int64) async {
        await MainActor.run {
            stagingKey = nil
            plan.plan(streamKey: streamKey, bytes: bytes)
            report()
        }
    }

    nonisolated func runMayGoOn() async -> Bool {
        await MainActor.run { !BackupDeviceConditions.isSessionLive }
    }

    nonisolated func runConfirmed(streamKey: String, bytes: Int64) async {
        await MainActor.run {
            plan.confirm(streamKey: streamKey, bytes: bytes)
            inFlightBytes = 0
            networkHold = nil
            report()
        }
    }

    /// One stream plans once, so the second target confirms the
    /// same bytes again. The total counts the plan once per target.
    private func report() {
        guard let progress else { return }
        progress.totalUnitCount = max(1, totalBytes)
        progress.completedUnitCount = completedBytes
    }

    private var totalBytes: Int64 { plan.plannedBytes * Int64(max(1, targetCount)) }

    /// A finished target counts as one full share of the plan, whether
    /// it confirmed every blob or already held them all. The target in
    /// flight adds only what it confirmed itself.
    private var completedBytes: Int64 {
        let doneTargets = plan.plannedBytes * Int64(targetsDone)
        let thisTarget = plan.confirmedBytes - confirmedBeforeThisTarget
        return min(totalBytes, doneTargets + thisTarget + inFlightBytes)
    }

    /// The share of every target's bytes that landed, or `nil`
    /// before the first stream reports its total.
    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return Double(completedBytes) / Double(totalBytes)
    }

    // MARK: - What the screens read

    /// Whether a pass is in flight, per 13.4. It brackets the pass
    /// and not the gates, so a trigger the gates refused shows no run
    /// block.
    var isRunning: Bool { startedAt != nil && finishedAt == nil }

    /// Whether the pill of 13.2 is on screen.
    var showsPill: Bool {
        ProgressPill.shows(
            startedAt: startedAt,
            finishedAt: finishedAt,
            hasUploads: plan.hasUploads,
            gameIsPlaying: BackupDeviceConditions.isSessionLive,
            stopped: stopLine != nil,
            now: now)
    }

    var phase: ProgressPill.Phase {
        if finishedAt != nil { return stopLine.map { .stopped(reason: $0) } ?? .complete }
        if let pause { return .paused(reason: pause.line) }
        if let networkHold { return .paused(reason: networkHold) }
        if let stagingKey { return .checking(gameName: gameName(of: stagingKey)) }
        guard let name = runningGameName else { return .checking(gameName: nil) }
        return .uploading(gameName: name)
    }

    var line: String {
        let left = totalBytes - completedBytes
        return ProgressPill.line(phase, leftText: left > 0 ? BackupText.bytes(left) : nil)
    }

    /// The name of the game the run uploads now, or `nil` while the
    /// run stages, or while it carries the preferences stream of
    /// 5.3, which belongs to no game.
    var runningGameName: String? {
        plan.streamKey.flatMap(gameName)
    }

    private func gameName(of streamKey: String) -> String? {
        streamKey == BackupStream.preferencesKey ? nil : namesByKey[streamKey]
    }

    func isDone(_ gameKey: String) -> Bool {
        plan.isDone(gameKey)
    }

    // MARK: - The clock

    /// The pill appears 2 seconds in and hides 5 seconds after the
    /// end, so something has to move the clock while nothing else
    /// changes.
    private func startTheTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.now = Date()
                guard let end = self.finishedAt else { continue }
                if self.now.timeIntervalSince(end) > ProgressPill.hideAfterStop {
                    self.ticker = nil
                    return
                }
            }
        }
    }
}

/// One game of the run block's queue, per 13.4.
struct BackupRunGameRow: Identifiable, Equatable {
    var gameKey: String
    var name: String

    var id: String { gameKey }
}

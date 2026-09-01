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
    /// The clock the pill's own 2-second and 5-second rules read.
    /// A timer moves it, because neither rule reacts to an event.
    private(set) var now = Date()

    private var namesByKey: [String: String] = [:]
    private var ticker: Task<Void, Never>?

    // MARK: - What the pass reports

    /// The pass starts and names what it covers.
    func runStarts(names: [String: String]) {
        namesByKey = names
        runningGameKeys = Set(names.keys)
        plan = BackupRunPlan()
        startedAt = Date()
        finishedAt = nil
        now = Date()
        queue =
            names
            .map { BackupRunGameRow(gameKey: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
        startTheTicker()
    }

    func runEnds() {
        finishedAt = Date()
        now = Date()
        runningGameKeys = []
    }

    nonisolated func runPlanned(streamKey: String, bytes: Int64) async {
        await MainActor.run { plan.plan(streamKey: streamKey, bytes: bytes) }
    }

    nonisolated func runConfirmed(streamKey: String, bytes: Int64) async {
        await MainActor.run { plan.confirm(streamKey: streamKey, bytes: bytes) }
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
            now: now)
    }

    var phase: ProgressPill.Phase {
        if finishedAt != nil { return .complete }
        if let pause { return .paused(reason: pause.line) }
        guard let name = runningGameName else { return .preparing }
        return .uploading(gameName: name)
    }

    var line: String {
        ProgressPill.line(phase, leftText: BackupText.bytes(plan.bytesLeft))
    }

    /// The name of the game the run uploads now, or `nil` while the
    /// run stages, or while it carries the preferences stream of
    /// 5.3, which belongs to no game.
    var runningGameName: String? {
        guard let key = plan.streamKey, key != BackupStream.preferencesKey else { return nil }
        return namesByKey[key]
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
                if self.now.timeIntervalSince(end) > ProgressPill.hideAfter {
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

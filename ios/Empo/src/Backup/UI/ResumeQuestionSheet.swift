import GameProbe
import SwiftUI

/// The question one launch asks, per SPEC 13.18, 6.5, and 11.9.
///
/// A run that stopped past 100 MB asks, and any unfinished restore
/// asks whatever its size. The same interruption never asks twice.
struct ResumeQuestionAsk: Identifiable {

    enum Side { case backupRun, restore }

    var side: Side
    var record: BackupIntentRecord
    var gameName: String
    var targetLabel: String

    var id: String { "\(side)" }

    var title: String {
        switch side {
        case .backupRun: return BackupResumeQuestion.title
        case .restore: return RestoreResumeQuestion.title
        }
    }

    var detail: String {
        switch side {
        case .backupRun:
            return BackupResumeQuestion.detail(
                gameName: gameName, targetLabel: targetLabel,
                leftText: BackupText.bytes(record.remainingBytes))
        case .restore:
            return RestoreResumeQuestion.detail(gameName: gameName, backupText: backupText)
        }
    }

    var stopTitle: String {
        switch side {
        case .backupRun: return BackupResumeQuestion.stopTitle
        case .restore: return RestoreResumeQuestion.stopTitle
        }
    }

    var stopDetail: String {
        switch side {
        case .backupRun:
            return BackupResumeQuestion.stopDetail(gameName: gameName, targetLabel: targetLabel)
        case .restore:
            return RestoreResumeQuestion.stopDetail(gameName: gameName)
        }
    }

    /// The three labels, in the order 13.18 puts them: resume, later,
    /// stop.
    var labels: [String] {
        switch side {
        case .backupRun:
            return BackupResumeQuestion.Action.allCases.map(BackupResumeQuestion.label)
        case .restore:
            return RestoreResumeQuestion.Action.allCases.map(RestoreResumeQuestion.label)
        }
    }

    private var backupText: String {
        guard let id = record.snapshotId, let date = BackupKeys.timestamp(ofSnapshotId: id)
        else { return "the backup on \(targetLabel)" }
        return "the backup of " + date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The one record the next launch asks about, or `nil` when the
    /// last launch left nothing.
    ///
    /// A half-restored game outranks an unfinished run, because it is
    /// the state that leaves files in two versions.
    @MainActor
    static func pending() -> ResumeQuestionAsk? {
        if let record = RestoreCoordinator.shared.pendingResume() {
            return ResumeQuestionAsk(side: .restore, record: record)
        }
        if let record = BackupScheduler.shared.pendingResume() {
            return ResumeQuestionAsk(side: .backupRun, record: record)
        }
        return nil
    }

    @MainActor
    private init(side: Side, record: BackupIntentRecord) {
        self.side = side
        self.record = record
        gameName = BackupGameNames().name(ofGameKey: record.gameKey)
        targetLabel =
            BackupTargets.load().first { $0.id == record.targetId }?.label ?? "the target"
    }

    /// Applies one answer by its place in `labels`.
    @MainActor
    func answer(_ index: Int) {
        switch side {
        case .backupRun:
            let action = BackupResumeQuestion.Action.allCases[index]
            BackupScheduler.shared.answerResume(action, gameName: gameName)
        case .restore:
            let action = RestoreResumeQuestion.Action.allCases[index]
            RestoreCoordinator.shared.answerResume(action, record: record)
            guard RestoreResumeQuestion.effect(of: action).startsRestoreNow else { return }
            Task { await RestoreCoordinator.shared.resume(record) }
        }
    }
}

/// The sheet the question shows, in two steps.
///
/// The first step asks Resume. Stop sits one step deeper, where the
/// title asks again and the body says what stays. The close icon is
/// Not now, and so is a swipe down.
struct ResumeQuestionSheet: View {

    private enum Step { case ask, stop }

    let ask: ResumeQuestionAsk

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .ask
    @State private var answered = false

    var body: some View {
        StandardSheet(
            title: step == .ask ? ask.title : ask.stopTitle,
            barAction: step == .ask
                ? SheetBarAction(ask.labels[1]) { answer(1) }
                : SheetBarAction("Back", symbol: .back) { show(.ask) }
        ) {
            Group {
                switch step {
                case .ask:
                    SheetBodyText(ask.detail, naming: ask.gameName)
                    VStack(spacing: Spacing.md) {
                        SheetPrimaryButton(ask.labels[0]) { answer(0) }
                        SheetQuietButton(ask.labels[2]) { show(.stop) }
                    }
                case .stop:
                    SheetBodyText(ask.stopDetail, naming: ask.gameName)
                    SheetDestructiveButton(ask.labels[2]) { answer(2) }
                }
            }
            .transition(.sheetStep)
        }
        .onDisappear {
            guard !answered else { return }
            ask.answer(1)
        }
    }

    private func show(_ next: Step) {
        withAnimation(Motion.gentle) { step = next }
    }

    private func answer(_ index: Int) {
        answered = true
        ask.answer(index)
        dismiss()
    }
}

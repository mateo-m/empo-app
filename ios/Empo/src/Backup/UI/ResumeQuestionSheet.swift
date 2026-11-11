import GameProbe
import SwiftUI

/// The question one launch asks, per SPEC 13.18, 6.5, and 11.9.
///
/// A run that stopped past 100 MB asks, and any unfinished restore
/// asks whatever its size. The same interruption never asks twice.
struct ResumeQuestionAsk: Identifiable {

    enum Side { case backupRun, restore }

    enum Answer { case resume, later, stop }

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
        switch record.work {
        case .run(_, let remainingBytes):
            return BackupResumeQuestion.detail(
                gameName: gameName, targetLabel: targetLabel,
                leftText: BackupText.bytes(remainingBytes))
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

    func label(_ answer: Answer) -> String {
        switch side {
        case .backupRun: return BackupResumeQuestion.label(of: backupAction(answer))
        case .restore: return RestoreResumeQuestion.label(of: restoreAction(answer))
        }
    }

    private func backupAction(_ answer: Answer) -> BackupResumeQuestion.Action {
        switch answer {
        case .resume: return .resume
        case .later: return .later
        case .stop: return .stop
        }
    }

    private func restoreAction(_ answer: Answer) -> RestoreResumeQuestion.Action {
        switch answer {
        case .resume: return .resume
        case .later: return .later
        case .stop: return .stop
        }
    }

    private var backupText: String {
        guard let id = record.snapshotId, let date = BackupKeys.timestamp(ofSnapshotId: id)
        else { return String(localized: "the backup on \(targetLabel)") }
        return String(localized: "the backup of \(date.formatted(date: .abbreviated, time: .shortened))")
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
            BackupTargets.load().first { $0.id == record.targetId }?.displayName
            ?? String(localized: "this location")
    }

    @MainActor
    func markAsked() {
        switch side {
        case .backupRun: BackupScheduler.shared.markResumeAsked()
        case .restore: RestoreCoordinator.shared.markResumeAsked()
        }
    }

    @MainActor
    func answer(_ answer: Answer) {
        switch side {
        case .backupRun:
            BackupScheduler.shared.answerResume(backupAction(answer), gameName: gameName)
        case .restore:
            let action = restoreAction(answer)
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
                ? SheetBarAction(ask.label(.later)) { answer(.later) }
                : SheetBarAction("Back", symbol: .back) { show(.ask) }
        ) {
            Group {
                switch step {
                case .ask:
                    SheetBodyText(ask.detail, naming: ask.gameName)
                    VStack(spacing: Spacing.md) {
                        SheetPrimaryButton(ask.label(.resume)) { answer(.resume) }
                        SheetQuietButton(ask.label(.stop)) { show(.stop) }
                    }
                case .stop:
                    SheetBodyText(ask.stopDetail, naming: ask.gameName)
                    SheetDestructiveButton(ask.label(.stop)) { answer(.stop) }
                }
            }
            .transition(.sheetStep)
        }
        .onAppear { ask.markAsked() }
        .onDisappear {
            guard !answered else { return }
            ask.answer(.later)
        }
    }

    private func show(_ next: Step) {
        withAnimation(Motion.gentle) { step = next }
    }

    private func answer(_ answer: ResumeQuestionAsk.Answer) {
        answered = true
        ask.answer(answer)
        dismiss()
    }
}

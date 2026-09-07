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
    var artworkPath: String?
    var targetLabel: String

    var id: String { "\(side)" }

    var emblem: String {
        switch side {
        case .backupRun: return "arrow.up.circle.dotted"
        case .restore: return "arrow.down.circle.dotted"
        }
    }

    var title: String {
        switch side {
        case .backupRun: return BackupResumeQuestion.title
        case .restore: return RestoreResumeQuestion.title
        }
    }

    var detail: String {
        switch side {
        case .backupRun:
            return BackupResumeQuestion.detail(gameName: gameName, targetLabel: targetLabel)
        case .restore:
            return RestoreResumeQuestion.detail(gameName: gameName)
        }
    }

    /// The second line of the game row: what is left, or which
    /// backup the restore came from.
    var gameLine: String {
        switch side {
        case .backupRun:
            return BackupResumeQuestion.leftLine(leftText: BackupText.bytes(record.remainingBytes))
        case .restore:
            guard let id = record.snapshotId, let date = BackupKeys.timestamp(ofSnapshotId: id)
            else { return "Backup on \(targetLabel)" }
            return "Backup from " + date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    var stopDetail: String {
        switch side {
        case .backupRun: return BackupResumeQuestion.stopDetail(gameName: gameName)
        case .restore: return RestoreResumeQuestion.stopDetail
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

    /// The one record the next launch asks about, or `nil` when the
    /// last launch left nothing.
    ///
    /// A half-restored game outranks an unfinished run, because it is
    /// the state that leaves files in two versions.
    @MainActor
    static func pending(games: [GameEntry]) -> ResumeQuestionAsk? {
        if let record = RestoreCoordinator.shared.pendingResume() {
            return ResumeQuestionAsk(side: .restore, record: record, games: games)
        }
        if let record = BackupScheduler.shared.pendingResume() {
            return ResumeQuestionAsk(side: .backupRun, record: record, games: games)
        }
        return nil
    }

    @MainActor
    private init(side: Side, record: BackupIntentRecord, games: [GameEntry]) {
        self.side = side
        self.record = record
        gameName = BackupGameNames().name(ofGameKey: record.gameKey)
        artworkPath = games.first {
            guard let folder = $0.container?.folderName else { return false }
            return BackupKeys.gameKey(containerFolderName: folder) == record.gameKey
        }?.artworkPath
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

/// The sheet the question shows.
///
/// Later is the bar action, and a swipe down means Later too, so the
/// record is marked asked whichever way the sheet goes.
struct ResumeQuestionSheet: View {

    let ask: ResumeQuestionAsk

    @Environment(\.dismiss) private var dismiss
    @State private var answered = false

    var body: some View {
        StandardSheet(
            title: ask.title,
            emblem: ask.emblem,
            trailingButton: SheetBarAction(ask.labels[1]) { answer(1) }
        ) {
            SheetBodyText(ask.detail)

            SheetCard {
                HStack(spacing: Spacing.lg) {
                    GameArtworkView(
                        artworkPath: ask.artworkPath,
                        placeholderIconSize: 20,
                        size: 44,
                        cornerRadius: Radius.sm
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ask.gameName)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(ask.gameLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
            }

            SheetCard {
                Button(role: .destructive) {
                    Haptics.tap()
                    answer(2)
                } label: {
                    HStack(spacing: Spacing.lg) {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.red)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ask.labels[2])
                                .foregroundStyle(.red)
                            Text(ask.stopDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            SheetPrimaryButton(ask.labels[0]) { answer(0) }
        }
        .onDisappear {
            guard !answered else { return }
            ask.answer(1)
        }
    }

    private func answer(_ index: Int) {
        answered = true
        ask.answer(index)
        dismiss()
    }
}

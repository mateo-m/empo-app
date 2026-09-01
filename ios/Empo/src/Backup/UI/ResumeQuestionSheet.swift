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

    var id: String { "\(side)" }

    var question: String {
        switch side {
        case .backupRun:
            return BackupResumeQuestion.question(
                gameName: gameName, leftText: BackupText.bytes(record.remainingBytes))
        case .restore:
            return RestoreResumeQuestion.question(gameName: gameName)
        }
    }

    /// The three labels, in the order 13.18 puts them.
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
    static func pending() -> ResumeQuestionAsk? {
        if let record = RestoreCoordinator.shared.pendingResume() {
            return ResumeQuestionAsk(
                side: .restore, record: record,
                gameName: BackupGameNames.name(ofGameKey: record.gameKey))
        }
        if let record = BackupScheduler.shared.pendingResume() {
            return ResumeQuestionAsk(
                side: .backupRun, record: record,
                gameName: BackupGameNames.name(ofGameKey: record.gameKey))
        }
        return nil
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
struct ResumeQuestionSheet: View {

    let ask: ResumeQuestionAsk

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text(ask.question)
                .font(.headline)

            VStack(spacing: Spacing.md) {
                ForEach(Array(ask.labels.enumerated()), id: \.offset) { index, label in
                    // Resume is the default, per 13.18, so it takes
                    // the one filled button.
                    if index == 0 {
                        Button(label) { answer(index) }
                            .buttonStyle(PrimaryButtonStyle(size: .md))
                            .frame(maxWidth: .infinity)
                    } else {
                        Button(label) { answer(index) }
                            .buttonStyle(SecondaryButtonStyle(size: .md))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(Spacing.xl)
        .presentationDetents([.height(280)])
    }

    private func answer(_ index: Int) {
        ask.answer(index)
        dismiss()
    }
}

/// The name one game key carries on screen.
enum BackupGameNames {

    @MainActor
    static func name(ofGameKey key: String?) -> String {
        guard let key else { return "your settings" }
        for container in GameContainer.discover()
        where BackupKeys.gameKey(containerFolderName: container.folderName) == key {
            let metadata = GameMetadata.load(from: container)
            return metadata.customTitle ?? metadata.baseTitle ?? container.folderName
        }
        return "this game"
    }
}

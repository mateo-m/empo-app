import Foundation

/// Why a restore stopped before it finished.
public enum RestoreStopReason: String, Error, Codable, Sendable, CaseIterable, Equatable {
    /// The user tapped cancel on the progress screen.
    case cancelled
    /// A game launched. That is the hard stop of 7.6, and it stops
    /// the restore at once.
    case gameLaunched = "game-launched"
    /// The disk filled despite the check of 11.8.
    case outOfSpace = "out-of-space"
    /// The target or the network failed.
    case targetFailed = "target-failed"
    /// The process died.
    case processDied = "process-died"
}

/// The resume question of SPEC 11.9 and 6.5.
///
/// Any unfinished restore leaves an intent record plus its staged
/// blobs. At the next launch Empo asks once, whatever the size,
/// because a half-restored game is not a state to leave quietly.
///
/// The same interruption never asks twice.
///
/// Ticket 018 builds the sheet. The rules are here.
public enum RestoreResumeQuestion {

    /// The three actions, per 11.9. Every one of them marks the
    /// record asked, because the question was asked.
    public enum Action: String, Codable, Sendable, CaseIterable, Equatable {
        /// Resume now.
        case resume
        /// Defer to the next run. The record stays.
        case later
        /// Stop the restore for good. The record clears and the
        /// staged files go.
        case stop
    }

    /// What one action does.
    public struct Effect: Equatable, Sendable {
        public var startsRestoreNow: Bool
        public var keepsRecord: Bool
        public var deletesStagedBlobs: Bool

        public init(startsRestoreNow: Bool, keepsRecord: Bool, deletesStagedBlobs: Bool) {
            self.startsRestoreNow = startsRestoreNow
            self.keepsRecord = keepsRecord
            self.deletesStagedBlobs = deletesStagedBlobs
        }
    }

    public static func question(gameName: String) -> String {
        "A restore was interrupted. Resume \(gameName)?"
    }

    public static func label(of action: Action) -> String {
        switch action {
        case .resume: return "Resume now"
        case .later: return "Later"
        case .stop: return "Stop this restore"
        }
    }

    /// Whether the question shows for this record.
    ///
    /// The record has to be an interrupted restore, and it has to
    /// have gone unasked. `BackupIntentRecord.asksAtNextLaunch`
    /// holds the second half, and it never applies the 100 MB floor
    /// of 6.5 to a restore.
    public static func asks(_ record: BackupIntentRecord?) -> Bool {
        guard let record, record.kind == .interruptedRestore else { return false }
        return record.asksAtNextLaunch
    }

    /// The record an interrupted restore leaves.
    public static func record(
        targetId: String, gameKey: String?, snapshotId: String, at date: Date
    ) -> BackupIntentRecord {
        BackupIntentRecord(
            kind: .interruptedRestore,
            targetId: targetId,
            gameKey: gameKey,
            snapshotId: snapshotId,
            createdAt: date)
    }

    public static func effect(of action: Action) -> Effect {
        switch action {
        case .resume:
            // The record clears when the restore finishes, not here,
            // so a second interruption still leaves one record.
            return Effect(startsRestoreNow: true, keepsRecord: true, deletesStagedBlobs: false)
        case .later:
            // The record stays for the next trigger. Marking it
            // asked is what keeps the same interruption from asking
            // twice.
            return Effect(startsRestoreNow: false, keepsRecord: true, deletesStagedBlobs: false)
        case .stop:
            return Effect(startsRestoreNow: false, keepsRecord: false, deletesStagedBlobs: true)
        }
    }
}

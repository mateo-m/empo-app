import Foundation

/// The resume question of SPEC 6.5 and 13.18, on the backup side.
///
/// A run that died with the process past the 100 MB floor asks once
/// at the next launch. Under the floor Empo recovers silently. The
/// restore side is `RestoreResumeQuestion`.
public enum BackupResumeQuestion {

    /// The three actions of 13.18.
    public enum Action: String, Codable, Sendable, CaseIterable, Equatable {
        /// The default. It continues now.
        case resume
        /// It leaves the intent record for the next trigger.
        case later
        /// It cancels the stream, cleans the staging and the outbox,
        /// and returns the game to ordinary scheduling.
        case stop
    }

    public struct Effect: Equatable, Sendable {
        public var startsRunNow: Bool
        public var keepsRecord: Bool
        public var cleansStagingAndOutbox: Bool

        public init(startsRunNow: Bool, keepsRecord: Bool, cleansStagingAndOutbox: Bool) {
            self.startsRunNow = startsRunNow
            self.keepsRecord = keepsRecord
            self.cleansStagingAndOutbox = cleansStagingAndOutbox
        }
    }

    /// `leftText` carries the remaining bytes in the words the caller
    /// formatted, such as "2.8 GB".
    public static func question(gameName: String, leftText: String) -> String {
        "Resume backing up \(gameName)? About \(leftText) left."
    }

    public static func label(of action: Action) -> String {
        switch action {
        case .resume: return "Resume"
        case .later: return "Later"
        case .stop: return "Stop backup"
        }
    }

    /// Whether the question shows for this record.
    ///
    /// `BackupIntentRecord.asksAtNextLaunch` holds the 100 MB floor
    /// and the once-only rule of 6.5. A pause never asks, because
    /// resume is one tap while the process lives.
    public static func asks(_ record: BackupIntentRecord?) -> Bool {
        guard let record, record.kind == .interruptedRun else { return false }
        return record.asksAtNextLaunch
    }

    public static func effect(of action: Action) -> Effect {
        switch action {
        case .resume:
            // The record clears when the run finishes, not here, so
            // a second interruption still leaves one record.
            return Effect(startsRunNow: true, keepsRecord: true, cleansStagingAndOutbox: false)
        case .later:
            // Marking the record asked is what keeps the same
            // interruption from asking twice.
            return Effect(startsRunNow: false, keepsRecord: true, cleansStagingAndOutbox: false)
        case .stop:
            return Effect(startsRunNow: false, keepsRecord: false, cleansStagingAndOutbox: true)
        }
    }
}

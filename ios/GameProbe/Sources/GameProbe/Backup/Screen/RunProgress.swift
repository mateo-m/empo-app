import Foundation

/// The run plan of SPEC 13.2.
///
/// Staging ends by producing it: every blob this snapshot needs,
/// minus every blob the local cache proves present. **That sum
/// freezes for the life of the run.** Each blob the provider
/// confirms adds its own size to the progress.
///
/// One stream plans once. A file that changes after that joins the
/// next snapshot and never inflates this one.
public struct BackupRunPlan: Equatable, Sendable {

    private var plannedByStream: [String: Int64] = [:]
    private var confirmedByStream: [String: Int64] = [:]
    public private(set) var confirmedBytes: Int64 = 0
    /// The stream the run uploads now.
    public private(set) var streamKey: String?

    public init() {}

    /// Freezes one stream's part of the plan. A second call for the
    /// same stream changes nothing.
    public mutating func plan(streamKey: String, bytes: Int64) {
        self.streamKey = streamKey
        guard plannedByStream[streamKey] == nil else { return }
        plannedByStream[streamKey] = bytes
    }

    public mutating func confirm(streamKey: String, bytes: Int64) {
        self.streamKey = streamKey
        confirmedByStream[streamKey, default: 0] += bytes
        confirmedBytes += bytes
    }

    public var plannedBytes: Int64 {
        plannedByStream.values.reduce(0, +)
    }

    public var bytesLeft: Int64 {
        max(0, plannedBytes - confirmedBytes)
    }

    /// A run with nothing to upload never shows the pill, per 13.2.
    public var hasUploads: Bool { plannedBytes > 0 }

    /// `nil` until the first stream freezes its plan. The badge and
    /// the pill draw a spinner until then, per 13.3.
    public var fraction: Double? {
        guard plannedBytes > 0 else { return nil }
        return min(1, Double(confirmedBytes) / Double(plannedBytes))
    }

    /// How far one stream is, for the card badge of 13.3.
    public func fraction(ofStream key: String) -> Double? {
        guard let planned = plannedByStream[key], planned > 0 else { return nil }
        return min(1, Double(confirmedByStream[key] ?? 0) / Double(planned))
    }

    /// Whether one stream has every blob of its plan on the target.
    public func isDone(_ key: String) -> Bool {
        guard let planned = plannedByStream[key] else { return false }
        return (confirmedByStream[key] ?? 0) >= planned
    }
}

/// The progress pill of SPEC 13.2.
public enum ProgressPill {

    /// It waits this long before it appears, so short work never
    /// flashes it.
    public static let showAfter: TimeInterval = 2
    /// It hides this long after the run finishes.
    public static let hideAfter: TimeInterval = 5

    /// What the pill says now.
    public enum Phase: Equatable, Sendable {
        /// The gap between one game's uploads and the next game's
        /// staging.
        case preparing
        case uploading(gameName: String)
        /// `reason` is the words of `StagingPause.line` or of
        /// `StaleCause.line`.
        case paused(reason: String)
        case complete
    }

    /// Whether the pill is on screen.
    ///
    /// A run with nothing to upload never shows it. The pill hides
    /// while a game plays, per 7.6, because the run is stopped
    /// anyway.
    public static func shows(
        startedAt: Date?,
        finishedAt: Date?,
        hasUploads: Bool,
        gameIsPlaying: Bool,
        now: Date
    ) -> Bool {
        guard let startedAt, hasUploads, !gameIsPlaying else { return false }
        guard now.timeIntervalSince(startedAt) >= showAfter else { return false }
        guard let finishedAt else { return true }
        return now.timeIntervalSince(finishedAt) < hideAfter
    }

    /// `leftText` carries the remaining bytes in the words the caller
    /// formatted, such as "2.4 GB".
    public static func line(_ phase: Phase, leftText: String? = nil) -> String {
        switch phase {
        case .preparing:
            return "Preparing…"
        case .uploading(let gameName):
            guard let leftText else { return "Backing up \(gameName)" }
            return "Backing up \(gameName), about \(leftText) left"
        case .paused(let reason):
            return "Paused, \(reason)"
        case .complete:
            return "Backup complete"
        }
    }
}

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

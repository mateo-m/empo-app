import Foundation

/// The progress pill of SPEC 13.2.
public enum ProgressPill {

    /// It waits this long before it appears, so short work never
    /// flashes it.
    public static let showAfter: TimeInterval = 2
    /// It hides this long after the run finishes.
    public static let hideAfter: TimeInterval = 5
    /// A stopped run keeps its line this long, so the cause reads.
    public static let hideAfterStop: TimeInterval = 15

    /// What the pill says now.
    public enum Phase: Equatable, Sendable {
        /// The engine reads and hashes one stream. `gameName` is
        /// `nil` for the preferences stream and for the gap between
        /// one game's uploads and the next game's staging.
        case checking(gameName: String?)
        case uploading(gameName: String)
        /// `reason` is the words of `StagingPause.line` or of
        /// `StaleCause.line`.
        case paused(reason: String)
        /// A target stopped on a cause the user must clear. `reason`
        /// is the words of `StaleCause.line`.
        case stopped(reason: String)
        case complete
    }

    /// The stop reason for a stop that no stale cause names, or
    /// `nil` where the pill can only say that the target did not
    /// finish.
    public static func stopReason(of stop: BackupRunStop, targetLabel: String) -> String? {
        switch stop {
        case .offline:
            return screenText("Empo couldn't connect to %@.", targetLabel)
        case .serverError:
            return screenText("%@ had a server error.", targetLabel)
        case .throttled:
            return screenText("%@ asked Empo to wait.", targetLabel)
        case .readOnlyFormat(.newerFormatVersion):
            return screenText("%@ needs a newer version of Empo.", targetLabel)
        case .readOnlyFormat(.unreadableFormat), .needsSignIn, .blocked, .full, .quotaShortfall, .rejected,
            .writerConflict,
            .gameStarted, .paused:
            return nil
        }
    }

    /// How a run ended. A stop keeps its line on screen longer.
    public enum End: Equatable, Sendable {
        case finished(at: Date)
        case stopped(at: Date)
    }

    /// Whether the pill is on screen.
    ///
    /// A run with nothing to upload never shows it. The pill hides
    /// while a game plays, per 7.6, because the run is stopped
    /// anyway.
    public static func shows(
        startedAt: Date?,
        end: End?,
        hasUploads: Bool,
        gameIsPlaying: Bool,
        now: Date
    ) -> Bool {
        guard let startedAt, hasUploads, !gameIsPlaying else { return false }
        guard now.timeIntervalSince(startedAt) >= showAfter else { return false }
        switch end {
        case nil: return true
        case .finished(let at): return now.timeIntervalSince(at) < hideAfter
        case .stopped(let at): return now.timeIntervalSince(at) < hideAfterStop
        }
    }

    /// `leftText` carries the remaining bytes in the words the caller
    /// formatted, such as "2.4 GB".
    public static func line(_ phase: Phase, leftText: String? = nil) -> String {
        switch phase {
        case .checking(let gameName):
            guard let gameName else { return screenText("Checking for changes…") }
            return screenText("Checking %@ for changes…", gameName)
        case .uploading(let gameName):
            guard let leftText else { return screenText("Backing up %@", gameName) }
            return screenText("Backing up %@, about %@ left", gameName, leftText)
        case .paused(let reason):
            return screenText("Paused, %@", reason)
        case .stopped(let reason):
            return screenText("Backup stopped. %@", reason)
        case .complete:
            return screenText("Backup complete")
        }
    }
}

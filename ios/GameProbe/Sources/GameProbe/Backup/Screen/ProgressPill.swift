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
        stopped: Bool = false,
        now: Date
    ) -> Bool {
        guard let startedAt, hasUploads, !gameIsPlaying else { return false }
        guard now.timeIntervalSince(startedAt) >= showAfter else { return false }
        guard let finishedAt else { return true }
        return now.timeIntervalSince(finishedAt) < (stopped ? hideAfterStop : hideAfter)
    }

    /// `leftText` carries the remaining bytes in the words the caller
    /// formatted, such as "2.4 GB".
    public static func line(_ phase: Phase, leftText: String? = nil) -> String {
        switch phase {
        case .checking(let gameName):
            guard let gameName else { return "Checking for changes…" }
            return "Checking \(gameName) for changes"
        case .uploading(let gameName):
            guard let leftText else { return "Backing up \(gameName)" }
            return "Backing up \(gameName), about \(leftText) left"
        case .paused(let reason):
            return "Paused, \(reason)"
        case .stopped(let reason):
            return "Backup stopped, \(reason)"
        case .complete:
            return "Backup complete"
        }
    }
}

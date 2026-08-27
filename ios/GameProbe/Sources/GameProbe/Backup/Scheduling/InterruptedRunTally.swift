import Foundation

/// The force-quit rule of SPEC 7.10.
///
/// Empo cannot see a force quit, only its wreckage. At launch, tasks
/// that vanished from the background session without completing
/// count as an interrupted run, and the foreground pass restarts
/// them.
public enum ForceQuitRule {

    /// How many consecutive lost runs the line waits for.
    public static let runsBeforeTheLine = 3

    /// The line the stale warning carries. One plain sentence in the
    /// app's voice. No scolding, and no modal.
    public static let habitLine = "The last three backups stopped when Empo closed."

    /// Whether the stale line names the habit.
    ///
    /// Two conditions, and both must hold: three consecutive runs
    /// lost this way, and the game already past the 7-day mark.
    /// People close apps for ordinary reasons, so the first time
    /// says nothing.
    public static func namesTheHabit(
        consecutiveInterruptedRuns: Int, level: StalenessLevel
    ) -> Bool {
        consecutiveInterruptedRuns >= runsBeforeTheLine && level >= .stale
    }
}

/// How one run ended, as the tally of 7.10 reads it.
public enum InterruptedRunEnding: Equatable, Sendable {
    /// The run's tasks vanished from the background session without
    /// completing. The process died with them.
    case interrupted
    /// The run closed a snapshot.
    case succeeded
    /// The run failed or stopped for a reason the process survived.
    /// It neither counts nor clears, because it is not the habit.
    case otherFailure
}

/// The count of consecutive runs lost to a force quit, per 7.10.
public struct InterruptedRunTally: Equatable, Sendable {

    public private(set) var count: Int

    public init(count: Int = 0) {
        self.count = max(0, count)
    }

    public mutating func record(_ ending: InterruptedRunEnding) {
        switch ending {
        case .interrupted: count += 1
        case .succeeded: count = 0
        case .otherFailure: break
        }
    }

    public func recording(_ ending: InterruptedRunEnding) -> InterruptedRunTally {
        var copy = self
        copy.record(ending)
        return copy
    }

    /// The cause the stale line carries, or `nil` while the habit
    /// has not shown itself.
    public func cause(level: StalenessLevel) -> StaleCause? {
        ForceQuitRule.namesTheHabit(consecutiveInterruptedRuns: count, level: level)
            ? .runsInterrupted : nil
    }
}

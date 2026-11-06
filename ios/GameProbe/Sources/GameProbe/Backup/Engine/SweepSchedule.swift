import Foundation

/// When the mark-and-sweep of SPEC 5.11 may run.
///
/// The engine owns the sweep's rules, and `BackupTriggerPlan.runsSweep`
/// picks the runs that take it. Two rules live here:
///
/// - An interrupted sweep is safe by construction, because it
///   deletes blobs and never manifests, so it resumes on the next
///   run. Nothing records where it stopped.
/// - A sweep stays queued while usage is under 80 percent of every
///   limit that governs: the provider quota against the whole
///   account, and the cap against Empo's own bytes. Space pressure
///   forces a sweep, not the calendar. A target with neither limit
///   has only the calendar.
///
/// The clock is a parameter, so the rule is repeatable.
public enum SweepSchedule {

    /// A sweep is due at 7 days per target.
    public static let dueAfter: TimeInterval = 7 * 86_400
    /// It is overdue at 30 days.
    public static let overdueAfter: TimeInterval = 30 * 86_400
    /// The usage that forces a sweep on a target that answers a
    /// space query.
    public static let pressureFraction = 0.80

    public enum Decision: Equatable, Sendable {
        /// The calendar has not reached 7 days.
        case notDue
        /// Due by the calendar, and held back because the target
        /// reports room to spare.
        case queued
        case run
        /// Due, and past 30 days. The foreground pass of 5.11 may
        /// take it as well as the nightly task.
        case runOverdue
    }

    /// Whether the calendar has reached the 7-day mark.
    public static func isDue(lastSweepAt: Date?, now: Date) -> Bool {
        guard let lastSweepAt else { return true }
        return now.timeIntervalSince(lastSweepAt) >= dueAfter
    }

    public static func isOverdue(lastSweepAt: Date?, now: Date) -> Bool {
        guard let lastSweepAt else { return true }
        return now.timeIntervalSince(lastSweepAt) >= overdueAfter
    }

    /// Whether the target has enough room that the sweep waits.
    public static func hasRoomToSpare(
        reading: QuotaReading?, capBytes: Int64?, storedBytes: Int64
    ) -> Bool {
        var usage: [Double] = []
        if let reading, let limit = reading.limitBytes, limit > 0 {
            usage.append(Double(reading.usedBytes) / Double(limit))
        }
        if let capBytes, capBytes > 0 {
            usage.append(Double(storedBytes) / Double(capBytes))
        }
        return !usage.isEmpty && usage.allSatisfy { $0 < pressureFraction }
    }

    public static func decide(
        lastSweepAt: Date?, now: Date, reading: QuotaReading?, capBytes: Int64?,
        storedBytes: Int64
    ) -> Decision {
        guard isDue(lastSweepAt: lastSweepAt, now: now) else { return .notDue }
        guard !hasRoomToSpare(reading: reading, capBytes: capBytes, storedBytes: storedBytes)
        else { return .queued }
        return isOverdue(lastSweepAt: lastSweepAt, now: now) ? .runOverdue : .run
    }
}

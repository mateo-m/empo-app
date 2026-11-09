import Foundation
import GameProbe
import UIKit

/// The `beginBackgroundTask` grant of SPEC 7.3, and what a run does
/// when it ends.
///
/// Local work at play-session end runs under a background task, then
/// the file-based upload tasks go to the background URLSession. The
/// uploads survive suspension on their own, so the grant only has to
/// cover the staging.
///
/// **The grant is measured, not published.** Apple states no number
/// for iOS 26, so every run logs what it got. Read the log line
/// `[BackupBackgroundTask] grant` on a device to find the real one.
///
/// When the grant ends mid-staging, the run stops on the file
/// boundary it is on, keeps the staging directory, and restarts at
/// the next trigger. That is the same rule a game launch follows,
/// per 7.6, and it holds for the same reason: a half-copied file is
/// worth nothing, and a whole one is worth keeping.
@MainActor
enum BackupBackgroundTask {

    /// Runs `body` under a background task and reports whether it
    /// finished before the grant ended.
    ///
    /// `body` must check `Task.isCancelled` on every file boundary.
    /// The expiry handler cancels it, and iOS kills the app when the
    /// handler returns late.
    @discardableResult
    static func run(
        named name: String, _ body: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let application = UIApplication.shared
        let startedAt = Date()

        var identifier = UIBackgroundTaskIdentifier.invalid
        let work = Task { await body() }
        identifier = application.beginBackgroundTask(withName: name) {
            work.cancel()
            BackupLog.line(
                "BackupBackgroundTask",
                "the grant ended after \(seconds(Date().timeIntervalSince(startedAt))) of \(name)")
            application.endBackgroundTask(identifier)
            identifier = .invalid
        }
        guard identifier != .invalid else {
            // iOS refused the task, so it can suspend the app at any
            // time. The work stops now, and the next trigger takes
            // what is left.
            BackupLog.line("BackupBackgroundTask", "iOS granted no background task for \(name)")
            work.cancel()
            return false
        }

        // The number is only real after the task starts. In the
        // foreground, and under a debugger, iOS reports an unlimited
        // grant.
        BackupLog.line(
            "BackupBackgroundTask",
            "grant \(seconds(application.backgroundTimeRemaining)) at start of \(name)")

        await work.value
        let finished = !work.isCancelled
        if identifier != .invalid {
            BackupLog.line(
                "BackupBackgroundTask", "\(name) ended after \(seconds(Date().timeIntervalSince(startedAt)))")
            application.endBackgroundTask(identifier)
        }
        return finished
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value > 1_000 ? "unlimited" : String(format: "%.1fs", value)
    }
}

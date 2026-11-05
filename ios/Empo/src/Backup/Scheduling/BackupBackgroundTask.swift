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
            log("the grant ended after \(seconds(Date().timeIntervalSince(startedAt))) of \(name)")
            application.endBackgroundTask(identifier)
            identifier = .invalid
        }
        guard identifier != .invalid else {
            // iOS refused the task, which means no grant at all. The
            // run stays in the foreground and the next trigger takes
            // what is left.
            log("iOS granted no background task for \(name)")
            work.cancel()
            return false
        }

        // The number is only real after the task starts. In the
        // foreground, and under a debugger, iOS reports an unlimited
        // grant.
        log("grant \(seconds(application.backgroundTimeRemaining)) at start of \(name)")

        await work.value
        let finished = !work.isCancelled
        if identifier != .invalid {
            log("\(name) ended after \(seconds(Date().timeIntervalSince(startedAt)))")
            application.endBackgroundTask(identifier)
        }
        return finished
    }

    #if DEBUG
    /// `backgroundTimeRemaining` reads as unlimited while the app
    /// still runs in the foreground, so measuring the grant needs a
    /// hold that logs the time left from inside the background task.
    static func holdForADeviceCheck() async {
        guard UserDefaults.standard.bool(forKey: "backupHoldGrant") else { return }
        while !Task.isCancelled {
            let left = UIApplication.shared.backgroundTimeRemaining
            log("the hold sees \(seconds(left)) left")
            try? await Task.sleep(for: .seconds(5))
        }
        log("the hold stopped")
    }
    #endif

    private static func seconds(_ value: TimeInterval) -> String {
        value > 1_000 ? "unlimited" : String(format: "%.1fs", value)
    }

    /// Always logged, whatever the debug setting says. The device
    /// check of ticket 007 has to read it on a clean install.
    private static func log(_ message: String) {
        BackupLog.line("BackupBackgroundTask", message)
    }
}

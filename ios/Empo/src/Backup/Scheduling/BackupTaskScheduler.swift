import BackgroundTasks
import Foundation
import GameProbe

/// The two iOS background tasks of SPEC 7.3.
///
/// The overnight `BGProcessingTask` is insurance and not a promise.
/// The continued-processing task belongs to the manual button alone,
/// because Apple forbids it for automatic work. `BGAppRefreshTask` is
/// dropped, per section 2, and nothing here adds it back.
@MainActor
enum BackupTaskScheduler {

    // MARK: - Identifiers

    /// The bundle id of the dev build and of the release build are
    /// not the same, so every identifier grows from it. `Info.plist`
    /// lists the same two under `BGTaskSchedulerPermittedIdentifiers`
    /// with `$(PRODUCT_BUNDLE_IDENTIFIER)` in front.
    private static var bundleId: String {
        Bundle.main.bundleIdentifier ?? "sh.mateo.empo"
    }

    static var nightlyIdentifier: String { "\(bundleId).backup.nightly" }

    /// The family of every manual identifier. `Info.plist` advertises
    /// it as `<this>.*`, and each press submits one identifier below
    /// it.
    static var manualPrefix: String { "\(bundleId).backup.manual" }

    /// The press travels in the identifier, so a task that starts
    /// after Empo restarts still knows what the user asked for. A
    /// game key is already hex, per `BackupKeys.gameKey`, so it needs
    /// no escape.
    static func identifier(for press: ManualBackupPress) -> String {
        switch press {
        case .library:
            return "\(manualPrefix).library"
        case .game(let gameKey, _):
            return "\(manualPrefix).game.\(gameKey)"
        }
    }

    /// Reads the press back out of a task. The name comes from the
    /// title the request carried, which the system keeps.
    static func press(identifier: String, title: String) -> ManualBackupPress? {
        if identifier == "\(manualPrefix).library" { return .library }
        let gamePrefix = "\(manualPrefix).game."
        guard identifier.hasPrefix(gamePrefix) else { return nil }
        let gameKey = String(identifier.dropFirst(gamePrefix.count))
        guard !gameKey.isEmpty else { return nil }
        return .game(gameKey: gameKey, gameName: title)
    }

    // MARK: - Registration

    /// Registers the overnight launch handler.
    ///
    /// `BGTaskScheduler` wants every handler in place before launch
    /// ends, so the app delegate calls this from
    /// `application(_:didFinishLaunchingWithOptions:)`. A second call
    /// for the same identifier kills the app, so the flag below stops
    /// one.
    ///
    /// The manual handler is not here. `BGTaskScheduler` refuses a
    /// registration whose identifier holds a `*`, and the concrete
    /// identifier of a press is not known until the press. Continued
    /// processing is the one kind of task the framework lets an app
    /// register after launch, per its header, so `submitManual`
    /// registers each identifier as it needs it. The press comes from
    /// a running app, so the handler is always in place in time.
    static func register() {
        guard !didRegister else { return }
        didRegister = true

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: nightlyIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in handleNightly(task) }
        }
    }

    private static var didRegister = false

    /// The manual identifiers that already have a handler. A second
    /// registration of one identifier kills the app.
    private static var registeredPresses: Set<String> = []

    // MARK: - The overnight pass

    /// Asks for the next overnight run.
    ///
    /// `requiresExternalPower` comes from `BackupTriggerPlan`, which
    /// grants it to this trigger alone, per 7.5. The date is the
    /// earliest the system may start, and the system decides the
    /// rest.
    static func scheduleNightly(after now: Date = Date()) {
        let request = BGProcessingTaskRequest(identifier: nightlyIdentifier)
        request.requiresExternalPower = BackupTriggerPlan.requiresExternalPower(.nightly)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = nextNight(after: now)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("[BackupTaskScheduler] the overnight request failed: %@", "\(error)")
        }
    }

    /// The next 02:00 in the local time zone.
    static func nextNight(after now: Date) -> Date {
        var parts = DateComponents()
        parts.hour = 2
        let next = Calendar.current.nextDate(
            after: now,
            matching: parts,
            matchingPolicy: .nextTime)
        return next ?? now.addingTimeInterval(8 * 3600)
    }

    private static func handleNightly(_ task: BGProcessingTask) {
        // Ask for tomorrow first. A crash below must not end the
        // series.
        scheduleNightly()

        let work = Task { @MainActor in
            let done = await BackupScheduler.shared.run(trigger: .nightly)
            task.setTaskCompleted(success: done)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - The manual button

    /// Submits one continued-processing task for one press, per 7.3
    /// and 13.11.
    ///
    /// The two entry points are the Backup sheet of one game and the
    /// Backups screen. There is no third. Returns false when the
    /// system refuses the request, and the caller then runs the pass
    /// in the foreground.
    @discardableResult
    static func submitManual(_ press: ManualBackupPress) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        let taskIdentifier = identifier(for: press)
        registerPress(taskIdentifier)
        let request = BGContinuedProcessingTaskRequest(
            identifier: taskIdentifier,
            title: BackupTriggerPlan.taskTitle(for: press),
            subtitle: startingLine)
        // The queue strategy waits for room instead of failing. iOS
        // drops a queued request when the user closes Empo from the
        // app switcher, which is the answer the user asked for.
        request.strategy = .queue
        // `requiredResources` stays at its default. The GPU option
        // needs an entitlement Empo does not carry, and a backup run
        // moves bytes and never draws.
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            NSLog("[BackupTaskScheduler] the manual request failed: %@", "\(error)")
            return false
        }
    }

    /// What the Live Activity shows before the first file moves.
    static let startingLine = "Starting"

    /// Gives one press identifier its handler, once.
    ///
    /// `Info.plist` advertises the family as
    /// `<bundle id>.backup.manual.*`, and the wildcard there covers
    /// every identifier this makes.
    @available(iOS 26.0, *)
    private static func registerPress(_ taskIdentifier: String) {
        guard registeredPresses.insert(taskIdentifier).inserted else { return }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            Task { @MainActor in handleManual(task) }
        }
    }

    @available(iOS 26.0, *)
    private static func handleManual(_ task: BGContinuedProcessingTask) {
        guard let press = press(identifier: task.identifier, title: task.title) else {
            task.setTaskCompleted(success: false)
            return
        }

        let work = Task { @MainActor in
            let done = await BackupScheduler.shared.run(
                trigger: .manual,
                press: press,
                progress: task.progress)
            task.setTaskCompleted(success: done)
        }
        task.expirationHandler = { work.cancel() }
    }
}

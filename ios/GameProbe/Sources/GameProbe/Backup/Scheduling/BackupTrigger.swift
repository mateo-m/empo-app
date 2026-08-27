import Foundation

/// The four triggers of SPEC 7.3.
///
/// Background execution on iOS is opportunistic and never
/// scheduled, so no trigger is a promise. `BGAppRefreshTask` is
/// dropped, per section 2, and nothing here may bring it back.
public enum BackupTrigger: String, Codable, CaseIterable, Equatable, Sendable {

    /// Play-session end and app background. The backbone, because
    /// saves change there and it is the one moment Empo controls.
    /// Local work runs under `beginBackgroundTask`, then the upload
    /// tasks go to the background URLSession.
    case sessionEndOrBackground = "session-end-or-background"

    /// The catch-up path, while the user browses the library. It
    /// waits `foregroundDelay`, so launching Empo and tapping into a
    /// game scans nothing.
    case foreground

    /// The overnight `BGProcessingTask`. Insurance and not a
    /// promise: it gives several minutes about once a day if the
    /// user charges nightly, and the system kills it when the user
    /// picks up the device.
    case nightly

    /// "Back up now". On iOS 26 each press submits one
    /// `BGContinuedProcessingTask` with a Live Activity. Apple
    /// forbids that task for automatic work, so this is the only
    /// trigger that may use it.
    case manual
}

/// Which games one pass covers, per SPEC 7.3.
public enum BackupScanScope: Equatable, Sendable {
    /// The games the state store marked dirty: the runtime watcher
    /// saw writes, or the game was imported, updated, restored, or
    /// changed mode since the last run.
    case dirtyGames
    /// Every game in the library, with a stat pass over each tree.
    case wholeLibrary
    /// The one game the user pressed the button for, in the Backup
    /// sheet.
    case oneGame(gameKey: String)
}

/// Which press opened a manual run, per SPEC 7.3 and 13.11. There
/// are two entry points and no third.
public enum ManualBackupPress: Equatable, Sendable {
    /// The Backup sheet, for the player who just finished a long
    /// session.
    case game(gameKey: String, gameName: String)
    /// The Backups screen, for the user about to wipe their device.
    case library
}

/// What each trigger scans, when it runs, and which iOS mechanism it
/// may use.
public enum BackupTriggerPlan {

    /// The foreground pass waits this long after the app becomes
    /// active, per 7.3.
    public static let foregroundDelay: TimeInterval = 30

    /// The title of the Live Activity a manual press carries, per
    /// 7.3.
    public static let libraryTaskTitle = "Empo backups"

    /// The games one trigger covers.
    ///
    /// The stream that belongs to no game is not here. It goes on
    /// every run and it goes first, per 7.8.
    public static func scope(
        of trigger: BackupTrigger, press: ManualBackupPress? = nil
    ) -> BackupScanScope {
        switch trigger {
        case .sessionEndOrBackground:
            return .dirtyGames
        case .foreground, .nightly:
            return .wholeLibrary
        case .manual:
            if case .game(let gameKey, _) = press { return .oneGame(gameKey: gameKey) }
            return .wholeLibrary
        }
    }

    /// The game keys the pass covers, in the order the caller gave
    /// them. `RunOrdering` puts them in run order afterwards.
    public static func games(
        in scope: BackupScanScope, dirty: [DirtyMark], library: [String]
    ) -> [String] {
        switch scope {
        case .dirtyGames:
            let marked = Set(dirty.map(\.gameKey))
            return library.filter(marked.contains)
        case .wholeLibrary:
            return library
        case .oneGame(let gameKey):
            return library.filter { $0 == gameKey }
        }
    }

    /// Whether this trigger may take the sweep of 5.11.
    ///
    /// The nightly task owns it. The foreground pass takes it only
    /// once it is overdue, per 5.11.
    public static func runsSweep(
        _ trigger: BackupTrigger, decision: SweepSchedule.Decision
    ) -> Bool {
        switch trigger {
        case .nightly:
            return decision == .run || decision == .runOverdue
        case .foreground:
            return decision == .runOverdue
        case .sessionEndOrBackground, .manual:
            return false
        }
    }

    /// The nightly task sets `requiresExternalPower`, per 7.5. That
    /// hands battery level, Low Power Mode, and the energy budget to
    /// the system.
    public static func requiresExternalPower(_ trigger: BackupTrigger) -> Bool {
        trigger == .nightly
    }

    /// Whether this trigger may submit a `BGContinuedProcessingTask`.
    /// Apple forbids it for automatic work, so only the manual
    /// button may.
    public static func usesContinuedProcessing(_ trigger: BackupTrigger) -> Bool {
        trigger == .manual
    }

    /// The title the continued-processing task and its Live Activity
    /// carry: the game name, or "Empo backups" for the library-wide
    /// press.
    public static func taskTitle(for press: ManualBackupPress) -> String {
        switch press {
        case .game(_, let gameName):
            return gameName
        case .library:
            return libraryTaskTitle
        }
    }
}

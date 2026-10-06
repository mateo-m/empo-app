import Foundation

/// What the Backup sheet of SPEC 13.17 lets the user touch.
public struct BackupSheetLocks: Equatable, Sendable {

    /// "Back up now" reads Pause instead, because a run for this
    /// game is in flight.
    public var backUpNowIsPause: Bool
    public var canBackUpNow: Bool
    public var canRestore: Bool
    public var canExport: Bool
    public var canDeleteLeftovers: Bool
    public var canChangeMode: Bool
    /// The save-file editor stays readable in every case. This is
    /// whether it also writes.
    public var canEditSaveFiles: Bool
    /// The one line that names why, or `nil` where nothing locks.
    public var footer: String?

    public init(
        backUpNowIsPause: Bool = false,
        canBackUpNow: Bool = true,
        canRestore: Bool = true,
        canExport: Bool = true,
        canDeleteLeftovers: Bool = true,
        canChangeMode: Bool = true,
        canEditSaveFiles: Bool = true,
        footer: String? = nil
    ) {
        self.backUpNowIsPause = backUpNowIsPause
        self.canBackUpNow = canBackUpNow
        self.canRestore = canRestore
        self.canExport = canExport
        self.canDeleteLeftovers = canDeleteLeftovers
        self.canChangeMode = canChangeMode
        self.canEditSaveFiles = canEditSaveFiles
        self.footer = footer
    }
}

/// The lock rules of SPEC 13.17.
///
/// One rule covers both cases: anything that writes the game
/// container waits.
public enum BackupSheetLockRules {

    public static let runInFlightLine = "A backup of this game is running."

    public static func gameIsOpenLine(_ gameName: String) -> String {
        "Close \(gameName) to use these."
    }

    /// `openGameName` is the game the player is in, whether it plays
    /// or sits paused in the library. The hard stop of 7.6 treats
    /// both the same way.
    public static func locks(runInFlight: Bool, openGameName: String?) -> BackupSheetLocks {
        if let openGameName {
            // The mode row and the editor write only
            // `EmpoState/backup.json` and take effect on the next
            // run, so they stay editable.
            return BackupSheetLocks(
                canBackUpNow: false,
                canRestore: false,
                canExport: false,
                canDeleteLeftovers: false,
                footer: gameIsOpenLine(openGameName))
        }
        guard runInFlight else { return BackupSheetLocks() }
        // Restoring into a tree whose snapshot is mid-upload would
        // ship a half-restored game.
        return BackupSheetLocks(
            backUpNowIsPause: true,
            canRestore: false,
            canChangeMode: false,
            canEditSaveFiles: false,
            footer: runInFlightLine)
    }
}

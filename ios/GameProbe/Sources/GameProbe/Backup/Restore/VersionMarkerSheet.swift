import Foundation

/// The version-marker sheet of SPEC 11.10.
///
/// It shows in one case: a full-mode restore over a tree whose
/// version marker of 4.4 differs. A restore of saves and settings
/// only never shows it, because that path carries no version risk.
///
/// The sheet names no version number. The marker compares hashes and
/// counts, so Empo never knows a version number to print, and games
/// carry version schemes of their own that any Empo claim would
/// collide with.
public enum VersionMarkerSheet {

    public enum Action: String, Codable, Sendable, CaseIterable, Equatable {
        case savesAndSettingsOnly = "saves-and-settings-only"
        case keepMyFiles = "keep-my-files"
        case useOnlyThisBackup = "use-only-this-backup"

        public var scope: RestoreScope {
            self == .savesAndSettingsOnly ? .savesAndSettings : .wholeGame
        }

        /// Per 11.12.
        public var replacesTheTree: Bool {
            self == .useOnlyThisBackup
        }

        public var label: String {
            switch self {
            case .savesAndSettingsOnly: return screenText("Saves and settings only")
            case .keepMyFiles: return screenText("Keep my files")
            case .useOnlyThisBackup: return screenText("Use only this backup")
            }
        }

        public var detail: String {
            switch self {
            case .savesAndSettingsOnly:
                return screenText("Puts back your saves, settings, and control layouts. Touches nothing else.")
            case .keepMyFiles:
                return screenText("Adds this backup's files beside yours. Removes nothing.")
            case .useOnlyThisBackup:
                return
                    screenText("Moves the game files here aside, then puts this backup's files in their "
                    + "place. The moved files stay in a folder you can open later.")
            }
        }
    }

    public static let title = screenText("Different game files")

    public static func body(gameName: String) -> String {
        screenText("This backup holds different game files than %@ has on this device. Mixing two "
            + "sets of game files can break the game.\n\nWhat should happen to the game files "
            + "already here?", gameName)
    }

    /// Saves and settings only is first, because it is the safe
    /// first choice.
    public static let actions: [Action] = [
        .savesAndSettingsOnly, .keepMyFiles, .useOnlyThisBackup,
    ]

    /// Whether the sheet shows before this restore, per 4.4 and
    /// 11.10.
    ///
    /// Both halves of "a full-mode restore" have to hold. The scope
    /// has to be the whole game, and the snapshot has to be a
    /// full-mode one. A slim snapshot carries no game files, so it
    /// can bury nothing and the sheet's three actions would read as
    /// noise.
    public static func shows(
        mode: BackupMode, scope: RestoreScope, markerDiffers: Bool
    ) -> Bool {
        guard scope == .wholeGame else { return false }
        return VersionMarkerBuilder.warnsBeforeRestore(
            mode: mode, differs: markerDiffers)
    }
}

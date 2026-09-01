import Foundation
import GameProbe

/// Every UserDefaults key this app reads or writes, in two shapes:
///
///   - Fixed names: a `PreferenceKey` from `PreferenceKeys`, which
///     carries the backup class SPEC 10.1 requires. A key that names
///     no class does not compile.
///   - Key families: `static func key(for: ...) -> String`, for
///     per-entity storage such as per-game or per-tip.
///
/// A third shape, enum-backed families under `experimental.*`, is
/// gone with the `ExperimentalFeature` enum. The tombstone comment
/// in `AppSettings.swift` records how to bring both back.
enum DefaultsKey {
    // MARK: - App-wide

    static let theme = PreferenceKeys.theme.name
    static let debugMode = PreferenceKeys.debugMode.name
    static let showViewportBounds = PreferenceKeys.showViewportBounds.name
    static let showTouchZone = PreferenceKeys.showTouchZone.name
    static let debugLogs = PreferenceKeys.debugLogs.name
    static let maxLogFiles = PreferenceKeys.maxLogFiles.name
    static let interfaceHaptics = PreferenceKeys.interfaceHaptics.name
    static let controllerHaptics = PreferenceKeys.controllerHaptics.name
    static let caBundleLastRefresh = PreferenceKeys.caBundleLastRefresh.name

    /// Controls edit mode: drags land on a fixed grid. Bool.
    static let controlsEditSnapToGrid = PreferenceKeys.controlsEditSnapToGrid.name

    // MARK: - Cloud backups

    /// "Back up over cellular", the one app-wide network switch of
    /// SPEC 7.4. Bool, off by default. There is no per-target
    /// override, and Low Data Mode has no toggle at all.
    static let backupOverCellular = PreferenceKeys.backupOverCellular.name

    /// The retention preset of SPEC 5.10, as a
    /// `RetentionPreset` raw value. One app-wide value, with no
    /// per-game control. Absent means standard.
    static let backupRetention = PreferenceKeys.backupRetention.name

    /// Empo already asked for notification permission. It asks after
    /// the user configures their first backup target, never at first
    /// launch, per SPEC 7.11. Bool.
    static let backupNotificationsAsked = PreferenceKeys.backupNotificationsAsked.name

    /// Empo spent its one chance at the system notification prompt.
    /// Only "Turn on" on the sheet of SPEC 13.19 sets it. "Not now"
    /// marks nothing, so the one chance stays unspent. Bool.
    static let backupNotificationPromptSpent = PreferenceKeys.backupNotificationPromptSpent.name

    // MARK: - Disclaimer

    static let disclaimerAcknowledgedVersion = PreferenceKeys.disclaimerAcknowledgedVersion.name

    // MARK: - Library

    /// Folder names (inside `Duplicate Games/`) of legacy duplicate
    /// imports the container migration moved out of the library.
    /// `[String]`. Non-empty means the library owes the user a
    /// one-time explanatory alert. Cleared once it's shown.
    static let pendingDuplicateGameNames = PreferenceKeys.pendingDuplicateGameNames.name

    /// Recoveries the pre-literal save heal performed, queued for
    /// the one-time library sheet. A `SaveRecoveryLedger` JSON
    /// blob (`Data`). Non-empty means the library owes the user
    /// the sheet. Cleared once shown.
    static let pendingSaveRecoveries = PreferenceKeys.pendingSaveRecoveries.name

    static let cleanupInvalidGames = PreferenceKeys.cleanupInvalidGames.name
    static let libraryDisplayMode = PreferenceKeys.libraryDisplayMode.name
    static let librarySortOption = PreferenceKeys.librarySortOption.name
    static let showContinuePlaying = PreferenceKeys.showContinuePlaying.name
    static let titlePosition = PreferenceKeys.titlePosition.name

    // MARK: - Viewport bounds overlay color

    static let viewportBoundsR = PreferenceKeys.viewportBoundsR.name
    static let viewportBoundsG = PreferenceKeys.viewportBoundsG.name
    static let viewportBoundsB = PreferenceKeys.viewportBoundsB.name
    static let viewportBoundsA = PreferenceKeys.viewportBoundsA.name

    // MARK: - Layout profiles

    /// The profile every game falls back to. It names a folder by
    /// string, so a dangling name reads as unset.
    static let layoutProfilesDefault = PreferenceKeys.layoutProfilesDefault.name

    /// The player showed the "this game ships its own layout" notice
    /// once. Bool.
    static let layoutProfilesGameNoticeShown = PreferenceKeys.layoutProfilesGameNoticeShown.name

    // MARK: - Player (parameterized families)

    /// LEGACY. Per-game controls layout, `controlsLayout.<gameID>`
    /// -> JSON. The live store is `EmpoState/controls.json`
    /// (`UserControlsFile`). This key survives only until
    /// `LegacyControlsMigration.run` moves it into the container and
    /// removes it, which a backup run and the player both call.
    static let controlsLayoutPrefix = PreferenceKeys.controlsLayoutPrefix
    static func controlsLayout(gameID: String) -> String {
        controlsLayoutPrefix + gameID
    }

    /// Global user controller overrides. `controllerMap.global` -> JSON (SPEC section 7).
    static let controllerMapGlobal = PreferenceKeys.controllerMapGlobal.name

    /// LEGACY, same migration as `controlsLayoutPrefix`. Per-game
    /// user controller overrides, `controllerMap.<gameID>` -> JSON.
    /// The live store is the `bindings` section of
    /// `EmpoState/controls.json`. `controllerMap.global` above is
    /// NOT legacy: global overrides still live here.
    static let controllerMapPrefix = PreferenceKeys.controllerMapPrefix
    static func controllerMap(gameID: String) -> String {
        controllerMapPrefix + gameID
    }

    // MARK: - Hints (parameterized family)

    /// A hint's dismissed-at timestamp. `hint.dismissed.<hintID>` -> Double.
    /// (UI hint persistence, not StoreKit / IAP / donations.)
    static let hintDismissedPrefix = PreferenceKeys.hintDismissedPrefix
    static func hintDismissed(hintID: String) -> String {
        hintDismissedPrefix + hintID
    }
}

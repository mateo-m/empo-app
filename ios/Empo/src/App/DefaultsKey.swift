import Foundation

/// Every UserDefaults key this app reads or writes, in three shapes:
///
///   - Fixed names: plain `static let`. Most keys.
///   - Key families: `static func key(for: ...) -> String`, for
///     per-entity storage such as per-game or per-tip.
///   - Enum-backed families: `ExperimentalFeature.rawValue` drives
///     the key set directly, prefixed `experimental.*` so the keys
///     stay grouped with the fixed names.
enum DefaultsKey {
    // MARK: - App-wide

    static let theme = "theme"
    static let debugMode = "debugMode"
    static let showViewportBounds = "showViewportBounds"
    static let showTouchZone = "showTouchZone"
    static let debugLogs = "debugLogs"
    static let maxLogFiles = "maxLogFiles"
    static let interfaceHaptics = "interfaceHaptics"
    static let controllerHaptics = "controllerHaptics"
    static let caBundleLastRefresh = "caBundleLastRefresh"

    /// Controls edit mode: drags land on a fixed grid. Bool.
    static let controlsEditSnapToGrid = "controlsEditSnapToGrid"

    // MARK: - Disclaimer

    static let disclaimerAcknowledgedVersion = "disclaimerAcknowledgedVersion"

    // MARK: - Library

    /// Folder names (inside `Duplicate Games/`) of legacy duplicate
    /// imports the container migration moved out of the library.
    /// `[String]`. Non-empty means the library owes the user a
    /// one-time explanatory alert. Cleared once it's shown.
    static let pendingDuplicateGameNames = "pendingDuplicateGameNames"

    /// Recoveries the pre-literal save heal performed, queued for
    /// the one-time library sheet. A `SaveRecoveryLedger` JSON
    /// blob (`Data`). Non-empty means the library owes the user
    /// the sheet. Cleared once shown.
    static let pendingSaveRecoveries = "pendingSaveRecoveries"

    static let cleanupInvalidGames = "cleanupInvalidGames"
    static let libraryDisplayMode = "libraryDisplayMode"
    static let librarySortOption = "librarySortOption"
    static let showContinuePlaying = "showContinuePlaying"
    static let titlePosition = "titlePosition"

    // MARK: - Viewport bounds overlay color

    static let viewportBoundsR = "vpBoundsR"
    static let viewportBoundsG = "vpBoundsG"
    static let viewportBoundsB = "vpBoundsB"
    static let viewportBoundsA = "vpBoundsA"

    // MARK: - Player (parameterized families)

    /// Per-game controls layout. `controlsLayout.<gameID>` -> JSON.
    static let controlsLayoutPrefix = "controlsLayout."
    static func controlsLayout(gameID: String) -> String {
        controlsLayoutPrefix + gameID
    }

    /// Global user controller overrides. `controllerMap.global` -> JSON (SPEC section 7).
    static let controllerMapGlobal = "controllerMap.global"

    /// Per-game user controller overrides. `controllerMap.<gameID>` -> JSON.
    static let controllerMapPrefix = "controllerMap."
    static func controllerMap(gameID: String) -> String {
        controllerMapPrefix + gameID
    }

    // MARK: - Hints (parameterized family)

    /// A hint's dismissed-at timestamp. `hint.dismissed.<hintID>` -> Double.
    /// (UI hint persistence, not StoreKit / IAP / donations.)
    static let hintDismissedPrefix = "hint.dismissed."
    static func hintDismissed(hintID: String) -> String {
        hintDismissedPrefix + hintID
    }
}

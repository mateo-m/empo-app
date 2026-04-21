import Foundation

/// Central registry of every UserDefaults key this app reads or
/// writes. Call sites reference these constants instead of literal
/// strings so that renaming a key is a one-line change and a grep
/// across the project surfaces every consumer immediately.
///
/// Three shapes are supported:
///
///   - Fixed-name keys: plain `static let` constants. Most keys.
///   - Parameterized key families: `static func key(for: ...) -> String`.
///     Use these for per-entity storage (e.g. per-game, per-tip).
///   - Enum-backed key families: the `ExperimentalFeature` enum's
///     `rawValue` drives the key set directly. The raw values are
///     namespaced with an `experimental.*` prefix so they stay visually
///     grouped alongside the fixed-name keys.
enum DefaultsKey {
    // MARK: - App-wide

    static let theme = "theme"
    static let debugMode = "debugMode"
    static let showViewportBounds = "showViewportBounds"
    static let debugLogs = "debugLogs"
    static let maxLogFiles = "maxLogFiles"
    static let interfaceHaptics = "interfaceHaptics"
    static let controllerHaptics = "controllerHaptics"

    // MARK: - Disclaimer

    static let disclaimerAcknowledgedVersion = "disclaimerAcknowledgedVersion"

    // MARK: - Library

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

    // MARK: - Tips (parameterized family)

    /// A tip's dismissed-at timestamp. `tip.dismissed.<tipID>` -> Double.
    static let tipDismissedPrefix = "tip.dismissed."
    static func tipDismissed(tipID: String) -> String {
        tipDismissedPrefix + tipID
    }
}

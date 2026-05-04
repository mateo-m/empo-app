import Foundation
import Observation
import SwiftUI
import UIKit

enum LibraryDisplayMode: String, CaseIterable {
    case grid = "grid"
    case list = "list"

    var label: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        }
    }
}

enum LibrarySortOption: String, CaseIterable {
    case titleAZ = "titleAZ"
    case titleZA = "titleZA"
    case recentlyAdded = "recentlyAdded"
    case leastRecentlyAdded = "leastRecentlyAdded"
    case recentlyPlayed = "recentlyPlayed"
    case leastRecentlyPlayed = "leastRecentlyPlayed"
    case mostPlayed = "mostPlayed"
    case leastPlayed = "leastPlayed"
    case largestSize = "largestSize"
    case smallestSize = "smallestSize"

    var label: String {
        switch self {
        case .titleAZ: "A → Z"
        case .titleZA: "Z → A"
        case .recentlyAdded: "Recently added"
        case .leastRecentlyAdded: "Least recently added"
        case .recentlyPlayed: "Recently played"
        case .leastRecentlyPlayed: "Least recently played"
        case .mostPlayed: "Most played"
        case .leastPlayed: "Least played"
        case .largestSize: "Largest first"
        case .smallestSize: "Smallest first"
        }
    }

    var icon: String {
        switch self {
        case .titleAZ, .titleZA: "textformat.abc"
        case .recentlyAdded, .leastRecentlyAdded: "tray.and.arrow.down"
        case .recentlyPlayed, .leastRecentlyPlayed: "clock"
        case .mostPlayed, .leastPlayed: "hourglass"
        case .largestSize, .smallestSize: "externaldrive"
        }
    }

    /// Groups for the sort sheet. Order here drives section order in
    /// the UI; each group's options also render in the listed order.
    static let groups: [LibrarySortGroup] = [
        LibrarySortGroup(title: "Title", options: [.titleAZ, .titleZA]),
        LibrarySortGroup(
            title: "Date",
            options: [
                .recentlyAdded, .leastRecentlyAdded,
                .recentlyPlayed, .leastRecentlyPlayed,
            ]),
        LibrarySortGroup(title: "Playtime", options: [.mostPlayed, .leastPlayed]),
        LibrarySortGroup(title: "Size", options: [.largestSize, .smallestSize]),
    ]
}

struct LibrarySortGroup: Identifiable {
    let title: String
    let options: [LibrarySortOption]
    var id: String { title }
}

enum TitlePosition: String, CaseIterable {
    case inside = "inside"
    case under = "under"

    var label: String {
        switch self {
        case .inside: "Inside card"
        case .under: "Under card"
        }
    }
}

enum AppTheme: String, CaseIterable {
    case dark = "dark"
    case light = "light"
    case auto = "auto"

    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .auto: "Auto"
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark: .dark
        case .light: .light
        case .auto: .unspecified
        }
    }
}

// `ExperimentalFeature` enum and its `isEnabled` / `setEnabled`
// machinery were removed in May 2026 once `gamePause` and `cheats`
// graduated to always-on, leaving no remaining experimental
// toggles. `gameQuit` was also planned as an experimental feature
// but never landed (cross-session Ruby state cleanup blocks it -
// see MRUBY_POSTMORTEM.md / QUIT_PATHS_DISABLED.md).
//
// To bring back an opt-in experimental toggle later, restore:
//   - this enum (cases + `label` + `description` + `id`)
//   - `AppSettings.experimentalFlags`, `isEnabled`, `setEnabled`
//   - the loop in `init` that loads the dictionary from defaults
//   - the `experimentalBinding(for:)` helper in `SettingsView`
//   - the `ForEach(ExperimentalFeature.allCases)` in `SettingsView`
//   - per-feature gating sites in PlayerMoreSheet etc.
//
// The DefaultsKey strings should re-use the historical
// `experimental.<name>` shape so users with the old toggle stored
// pick it back up automatically.

@MainActor
@Observable
class AppSettings {
    static let shared = AppSettings()

    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: DefaultsKey.theme) }
    }

    /// Toggle for the in-game Diagnostics overlay (the floating
    /// draggable panel showing title / Ruby version / renderer /
    /// FPS). The persistence key stays at `DefaultsKey.debugMode`
    /// for backward-compat with users who already toggled the
    /// setting under its earlier name; the Swift property and the
    /// user-facing label both moved to "diagnosticsOverlay".
    var diagnosticsOverlay: Bool {
        didSet { UserDefaults.standard.set(diagnosticsOverlay, forKey: DefaultsKey.debugMode) }
    }

    var showViewportBounds: Bool {
        didSet {
            UserDefaults.standard.set(showViewportBounds, forKey: DefaultsKey.showViewportBounds)
            mkxp_setShowViewportBounds(showViewportBounds)
        }
    }

    var viewportBoundsColor: Color {
        didSet {
            saveViewportBoundsColor()
            pushViewportBoundsColor()
        }
    }

    var debugLogs: Bool {
        didSet { UserDefaults.standard.set(debugLogs, forKey: DefaultsKey.debugLogs) }
    }

    var maxLogFiles: Int {
        didSet { UserDefaults.standard.set(maxLogFiles, forKey: DefaultsKey.maxLogFiles) }
    }

    var cleanupInvalidGames: Bool {
        didSet { UserDefaults.standard.set(cleanupInvalidGames, forKey: DefaultsKey.cleanupInvalidGames) }
    }

    var interfaceHaptics: Bool {
        didSet { UserDefaults.standard.set(interfaceHaptics, forKey: DefaultsKey.interfaceHaptics) }
    }

    var controllerHaptics: Bool {
        didSet { UserDefaults.standard.set(controllerHaptics, forKey: DefaultsKey.controllerHaptics) }
    }

    var titlePosition: TitlePosition {
        didSet { UserDefaults.standard.set(titlePosition.rawValue, forKey: DefaultsKey.titlePosition) }
    }

    var libraryDisplayMode: LibraryDisplayMode {
        didSet {
            UserDefaults.standard.set(libraryDisplayMode.rawValue, forKey: DefaultsKey.libraryDisplayMode)
        }
    }

    var showContinuePlaying: Bool {
        didSet { UserDefaults.standard.set(showContinuePlaying, forKey: DefaultsKey.showContinuePlaying) }
    }

    var librarySortOption: LibrarySortOption {
        didSet {
            UserDefaults.standard.set(librarySortOption.rawValue, forKey: DefaultsKey.librarySortOption)
        }
    }

    // MARK: - Splash disclaimer acknowledgment

    /// Monotonically increasing version so the flow can re-prompt when the
    /// disclaimer copy changes meaningfully.
    static let currentDisclaimerVersion = 1

    var disclaimerAcknowledgedVersion: Int {
        didSet {
            UserDefaults.standard.set(
                disclaimerAcknowledgedVersion, forKey: DefaultsKey.disclaimerAcknowledgedVersion)
        }
    }

    var needsDisclaimer: Bool {
        disclaimerAcknowledgedVersion < Self.currentDisclaimerVersion
    }

    func acknowledgeDisclaimer() {
        disclaimerAcknowledgedVersion = Self.currentDisclaimerVersion
    }

    private init() {
        let ud = UserDefaults.standard
        let themeRaw = ud.string(forKey: DefaultsKey.theme) ?? AppTheme.auto.rawValue
        self.theme = AppTheme(rawValue: themeRaw) ?? .auto
        self.diagnosticsOverlay = ud.bool(forKey: DefaultsKey.debugMode)
        self.showViewportBounds = ud.bool(forKey: DefaultsKey.showViewportBounds)
        self.viewportBoundsColor = Self.loadViewportBoundsColor()
        self.debugLogs = (ud.object(forKey: DefaultsKey.debugLogs) as? Bool) ?? true
        let storedMax = ud.integer(forKey: DefaultsKey.maxLogFiles)
        self.maxLogFiles = storedMax > 0 ? storedMax : 20
        self.cleanupInvalidGames = ud.bool(forKey: DefaultsKey.cleanupInvalidGames)
        // Haptics default to on - UserDefaults.bool returns false for unset keys
        self.interfaceHaptics = ud.object(forKey: DefaultsKey.interfaceHaptics) as? Bool ?? true
        self.controllerHaptics = ud.object(forKey: DefaultsKey.controllerHaptics) as? Bool ?? true
        let raw = ud.string(forKey: DefaultsKey.titlePosition) ?? TitlePosition.inside.rawValue
        self.titlePosition = TitlePosition(rawValue: raw) ?? .inside
        let modeRaw = ud.string(forKey: DefaultsKey.libraryDisplayMode) ?? LibraryDisplayMode.grid.rawValue
        self.libraryDisplayMode = LibraryDisplayMode(rawValue: modeRaw) ?? .grid
        self.showContinuePlaying = ud.object(forKey: DefaultsKey.showContinuePlaying) as? Bool ?? true
        let sortRaw = ud.string(forKey: DefaultsKey.librarySortOption) ?? LibrarySortOption.titleAZ.rawValue
        self.librarySortOption = LibrarySortOption(rawValue: sortRaw) ?? .titleAZ
        self.disclaimerAcknowledgedVersion = ud.integer(forKey: DefaultsKey.disclaimerAcknowledgedVersion)

        mkxp_setShowViewportBounds(showViewportBounds)
        pushViewportBoundsColor()
    }

    private static let defaultViewportBoundsColor = Color(
        .sRGB, red: 1.0, green: 0.584, blue: 0.0, opacity: 0.5)

    private static func loadViewportBoundsColor() -> Color {
        let ud = UserDefaults.standard
        guard ud.object(forKey: DefaultsKey.viewportBoundsR) != nil else { return defaultViewportBoundsColor }
        return Color(
            .sRGB,
            red: ud.double(forKey: DefaultsKey.viewportBoundsR),
            green: ud.double(forKey: DefaultsKey.viewportBoundsG),
            blue: ud.double(forKey: DefaultsKey.viewportBoundsB),
            opacity: ud.double(forKey: DefaultsKey.viewportBoundsA)
        )
    }

    private func resolvedRGBA() -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let resolved = UIColor(viewportBoundsColor)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    private func saveViewportBoundsColor() {
        let c = resolvedRGBA()
        let ud = UserDefaults.standard
        ud.set(Double(c.r), forKey: DefaultsKey.viewportBoundsR)
        ud.set(Double(c.g), forKey: DefaultsKey.viewportBoundsG)
        ud.set(Double(c.b), forKey: DefaultsKey.viewportBoundsB)
        ud.set(Double(c.a), forKey: DefaultsKey.viewportBoundsA)
    }

    func pushViewportBoundsColor() {
        let c = resolvedRGBA()
        mkxp_setViewportBoundsColor(Float(c.r), Float(c.g), Float(c.b), Float(c.a))
    }
}

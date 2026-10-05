import Foundation
import Observation
import SwiftUI
import UIKit

enum LibraryDisplayMode: String, CaseIterable {
    case grid
    case list

    var label: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        }
    }
}

enum LibrarySortOption: String, CaseIterable {
    case titleAZ
    case titleZA
    case recentlyAdded
    case leastRecentlyAdded
    case recentlyPlayed
    case leastRecentlyPlayed
    case mostPlayed
    case leastPlayed
    case largestSize
    case smallestSize

    var label: String {
        switch self {
        case .titleAZ: "Title A to Z"
        case .titleZA: "Title Z to A"
        case .recentlyAdded: "Recently added"
        case .leastRecentlyAdded: "Added longest ago"
        case .recentlyPlayed: "Recently played"
        case .leastRecentlyPlayed: "Played longest ago"
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

    /// Groups for the sort sheet. The order here drives the section
    /// order in the UI. Each group's options also render in the
    /// listed order.
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
    case inside
    case under

    var label: String {
        switch self {
        case .inside: "Inside card"
        case .under: "Under card"
        }
    }
}

enum AppTheme: String, CaseIterable {
    case dark
    case light
    case auto

    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .auto: "System"
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

/// Where a game runs: in the app, or in a game process of its own
/// (`GameProcessHost`). See ios/Empo/docs/multi-session.md.
enum GameRunner: String {
    case app
    case gameProcess
}

@MainActor
@Observable
class AppSettings {
    static let shared = AppSettings()

    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: DefaultsKey.theme) }
    }

    /// Toggle for the in-game Diagnostics overlay. The overlay is
    /// the floating draggable panel that shows title, Ruby version,
    /// renderer, and FPS. The persistence key stays at
    /// `DefaultsKey.debugMode` for backward compatibility with users
    /// who already set the toggle under its earlier name. The Swift
    /// property and the user-facing label both moved to
    /// "diagnosticsOverlay".
    var diagnosticsOverlay: Bool {
        didSet { UserDefaults.standard.set(diagnosticsOverlay, forKey: DefaultsKey.debugMode) }
    }

    var showViewportBounds: Bool {
        didSet {
            UserDefaults.standard.set(showViewportBounds, forKey: DefaultsKey.showViewportBounds)
            pushToCore()
        }
    }

    var viewportBoundsColor: Color {
        didSet {
            saveViewportBoundsColor()
            pushToCore()
        }
    }

    /// Outlines the in-game area where the app delivers touches to
    /// the game as mouse input (the visible game surface).
    var showTouchZone: Bool {
        didSet { UserDefaults.standard.set(showTouchZone, forKey: DefaultsKey.showTouchZone) }
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

    /// Where the games of `GameCores.gameProcessCores` run from the next
    /// launch. Experimental, and off
    /// (`.app`) by default.
    var rubyGameRunner: GameRunner {
        didSet { UserDefaults.standard.set(rubyGameRunner.rawValue, forKey: DefaultsKey.rubyGameRunner) }
    }

    /// `rubyGameRunner` until Empo closes. A game in the app stays
    /// for the life of the process, so a change applies at the next
    /// launch only. `.app` when the data cannot move into the app group.
    nonisolated static let rubyGameRunnerThisLaunch: GameRunner =
        DataDirectory.documentsRootURL == DataDirectory.appGroupURL ? .gameProcess : .app

    /// `DataDirectory` reads it before the main actor runs.
    nonisolated static var rubyGameRunnerChosen: GameRunner {
        let raw = UserDefaults.standard.string(forKey: DefaultsKey.rubyGameRunner) ?? ""
        return gameProcessIsAvailable ? GameRunner(rawValue: raw) ?? .app : .app
    }

    /// The game process needs a core that cannot kill its session, and
    /// the app group folder for the games and the saves.
    nonisolated static var gameProcessIsAvailable: Bool {
        !GameCores.gameProcessCores.isEmpty && DataDirectory.appGroupURL != nil
    }

    // MARK: - Splash disclaimer acknowledgment

    /// A version number that only increases. The flow can then prompt
    /// again when the disclaimer copy changes in a meaningful way.
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
        acknowledgeWhatsNew()
    }

    // MARK: - What's new

    var whatsNewSeenVersion: Int {
        didSet {
            UserDefaults.standard.set(whatsNewSeenVersion, forKey: DefaultsKey.whatsNewSeenVersion)
        }
    }

    var needsWhatsNew: Bool {
        whatsNewSeenVersion < WhatsNew.version
    }

    func acknowledgeWhatsNew() {
        whatsNewSeenVersion = WhatsNew.version
    }

    private init() {
        let ud = UserDefaults.standard
        let themeRaw = ud.string(forKey: DefaultsKey.theme) ?? AppTheme.auto.rawValue
        self.theme = AppTheme(rawValue: themeRaw) ?? .auto
        self.diagnosticsOverlay = ud.bool(forKey: DefaultsKey.debugMode)
        self.showViewportBounds = ud.bool(forKey: DefaultsKey.showViewportBounds)
        self.showTouchZone = ud.bool(forKey: DefaultsKey.showTouchZone)
        self.viewportBoundsColor = Self.loadViewportBoundsColor()
        self.debugLogs = (ud.object(forKey: DefaultsKey.debugLogs) as? Bool) ?? true
        let storedMax = ud.integer(forKey: DefaultsKey.maxLogFiles)
        self.maxLogFiles = storedMax > 0 ? storedMax : 20
        self.cleanupInvalidGames = ud.bool(forKey: DefaultsKey.cleanupInvalidGames)
        // Haptics default to on. UserDefaults.bool returns false for unset keys.
        self.interfaceHaptics = ud.object(forKey: DefaultsKey.interfaceHaptics) as? Bool ?? true
        self.controllerHaptics = ud.object(forKey: DefaultsKey.controllerHaptics) as? Bool ?? true
        let raw = ud.string(forKey: DefaultsKey.titlePosition) ?? TitlePosition.inside.rawValue
        self.titlePosition = TitlePosition(rawValue: raw) ?? .inside
        let modeRaw = ud.string(forKey: DefaultsKey.libraryDisplayMode) ?? LibraryDisplayMode.grid.rawValue
        self.libraryDisplayMode = LibraryDisplayMode(rawValue: modeRaw) ?? .grid
        self.showContinuePlaying = ud.object(forKey: DefaultsKey.showContinuePlaying) as? Bool ?? true
        let sortRaw = ud.string(forKey: DefaultsKey.librarySortOption) ?? LibrarySortOption.titleAZ.rawValue
        self.librarySortOption = LibrarySortOption(rawValue: sortRaw) ?? .titleAZ
        self.rubyGameRunner =
            GameRunner(rawValue: ud.string(forKey: DefaultsKey.rubyGameRunner) ?? "") ?? .app
        self.disclaimerAcknowledgedVersion = ud.integer(forKey: DefaultsKey.disclaimerAcknowledgedVersion)
        self.whatsNewSeenVersion = ud.integer(forKey: DefaultsKey.whatsNewSeenVersion)

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

    /// Pushes the settings the engine holds a copy of.
    ///
    /// The user can change these in the library, before any core is
    /// open. They live here until then, and
    /// `EngineSessionCoordinator.openCore` calls this once the core is
    /// in.
    func pushToCore() {
        guard EmpoCoreIsOpen() != 0 else { return }
        gamecore_setShowViewportBounds(showViewportBounds)
        let c = resolvedRGBA()
        gamecore_setViewportBoundsColor(Float(c.r), Float(c.g), Float(c.b), Float(c.a))
    }
}

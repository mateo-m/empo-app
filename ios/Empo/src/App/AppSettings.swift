// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import Observation
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum LibraryDisplayMode: String, CaseIterable {
    case grid
    case list

    var label: LocalizedStringResource {
        switch self {
        case .grid: LocalizedStringResource("Grid", comment: "Library layout option: games as cards.")
        case .list: LocalizedStringResource("List", comment: "Library layout option: games as rows.")
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

    var label: LocalizedStringResource {
        #if os(macOS)
        switch self {
        case .titleAZ: "Title A to Z"
        case .titleZA: "Title Z to A"
        case .recentlyAdded: "Recently Added"
        case .leastRecentlyAdded: "Added Longest Ago"
        case .recentlyPlayed: "Recently Played"
        case .leastRecentlyPlayed: "Played Longest Ago"
        case .mostPlayed: "Most Played"
        case .leastPlayed: "Least Played"
        case .largestSize: "Largest First"
        case .smallestSize: "Smallest First"
        }
        #else
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
        #endif
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
        LibrarySortGroup(
            title: LocalizedStringResource(
                "Title", comment: "Library sort sheet: section for sorting by game title."),
            options: [.titleAZ, .titleZA]),
        LibrarySortGroup(
            title: LocalizedStringResource(
                "Date", comment: "Library sort sheet: section for sorting by when a game was added or played."
            ),
            options: [
                .recentlyAdded, .leastRecentlyAdded,
                .recentlyPlayed, .leastRecentlyPlayed,
            ]),
        LibrarySortGroup(title: "Play time", options: [.mostPlayed, .leastPlayed]),
        LibrarySortGroup(
            title: LocalizedStringResource(
                "Size", comment: "Library sort sheet: section for sorting by game size on disk."),
            options: [.largestSize, .smallestSize]),
    ]
}

struct LibrarySortGroup: Identifiable {
    let title: LocalizedStringResource
    let options: [LibrarySortOption]
    var id: LibrarySortOption? { options.first }
}

enum TitlePosition: String, CaseIterable {
    case inside
    case under

    var label: LocalizedStringResource {
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

    var label: LocalizedStringResource {
        switch self {
        case .dark: LocalizedStringResource("Dark", comment: "Theme option.")
        case .light: LocalizedStringResource("Light", comment: "Theme option.")
        case .auto:
            LocalizedStringResource(
                "System", comment: "Option that follows the device setting, for the theme or the language.")
        }
    }

    #if os(iOS)
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark: .dark
        case .light: .light
        case .auto: .unspecified
        }
    }
    #endif
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

    var errorReports: Bool {
        didSet {
            UserDefaults.standard.set(errorReports, forKey: DefaultsKey.errorReports)
            #if os(iOS)
            ErrorReports.apply(enabled: errorReports)
            #endif
        }
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

    var respectsSilentMode: Bool {
        didSet {
            UserDefaults.standard.set(respectsSilentMode, forKey: DefaultsKey.respectsSilentMode)
            pushSilentModeToCore()
        }
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

    #if os(macOS)
    var quitClosesGamesWithoutAsking: Bool {
        didSet {
            UserDefaults.standard.set(
                quitClosesGamesWithoutAsking, forKey: DefaultsKey.quitClosesGamesWithoutAsking)
        }
    }
    #endif

    /// Where the games of `GameCores.gameProcessCores` run from the next
    /// launch. Experimental, and off
    /// (`.app`) by default.
    var rubyGameRunner: GameRunner {
        didSet { UserDefaults.standard.set(rubyGameRunner.rawValue, forKey: DefaultsKey.rubyGameRunner) }
    }

    /// `rubyGameRunner` until Empo closes. A game in the app stays
    /// for the life of the process, so a change applies at the next
    /// launch only.
    nonisolated static let rubyGameRunnerThisLaunch: GameRunner = {
        let raw = UserDefaults.standard.string(forKey: DefaultsKey.rubyGameRunner) ?? ""
        return gameProcessIsAvailable && DataDirectory.isInAppGroup ? GameRunner(rawValue: raw) ?? .app : .app
    }()

    /// The game process needs a core that cannot kill its session, and
    /// an app group for the games and the saves. A sideload tool can
    /// remove the extensions to save App IDs.
    nonisolated static var gameProcessIsAvailable: Bool {
        !GameCores.gameProcessCores.isEmpty
            && DataDirectory.appGroupURL != nil
            && FileManager.default.fileExists(
                atPath: Bundle.main.bundleURL.appendingPathComponent("Extensions/GameProcess.appex").path)
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
        #if os(iOS)
        acknowledgeWhatsNew()
        #endif
    }

    // MARK: - What's new

    var whatsNewSeenVersion: Int {
        didSet {
            UserDefaults.standard.set(whatsNewSeenVersion, forKey: DefaultsKey.whatsNewSeenVersion)
        }
    }

    #if os(iOS)
    var needsWhatsNew: Bool {
        // Accepting the disclaimer marks the news read, so a prompt
        // that waits behind the disclaimer would never open or finish.
        !needsDisclaimer && whatsNewSeenVersion < WhatsNew.version
    }

    func acknowledgeWhatsNew() {
        whatsNewSeenVersion = WhatsNew.version
    }
    #endif

    private init() {
        let stored = Stored(UserDefaults.standard)
        self.theme = stored.theme
        self.diagnosticsOverlay = stored.diagnosticsOverlay
        self.showViewportBounds = stored.showViewportBounds
        self.showTouchZone = stored.showTouchZone
        self.viewportBoundsColor = stored.viewportBoundsColor
        self.debugLogs = stored.debugLogs
        self.errorReports = stored.errorReports
        self.maxLogFiles = stored.maxLogFiles
        self.cleanupInvalidGames = stored.cleanupInvalidGames
        self.interfaceHaptics = stored.interfaceHaptics
        self.controllerHaptics = stored.controllerHaptics
        self.respectsSilentMode = stored.respectsSilentMode
        self.titlePosition = stored.titlePosition
        self.libraryDisplayMode = stored.libraryDisplayMode
        self.showContinuePlaying = stored.showContinuePlaying
        self.librarySortOption = stored.librarySortOption
        self.rubyGameRunner = stored.rubyGameRunner
        self.disclaimerAcknowledgedVersion = stored.disclaimerAcknowledgedVersion
        self.whatsNewSeenVersion = stored.whatsNewSeenVersion
        #if os(macOS)
        self.quitClosesGamesWithoutAsking = stored.quitClosesGamesWithoutAsking
        #endif
        // A settings restore and a sync pass write UserDefaults
        // directly.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppSettings.shared.reload() }
        }
    }

    /// Each `didSet` writes UserDefaults, and that write posts the
    /// change notification again, so only a changed value is set.
    private func reload() {
        let stored = Stored(UserDefaults.standard)
        func update<Value: Equatable>(_ path: ReferenceWritableKeyPath<AppSettings, Value>, _ value: Value) {
            if self[keyPath: path] != value { self[keyPath: path] = value }
        }
        update(\.theme, stored.theme)
        update(\.diagnosticsOverlay, stored.diagnosticsOverlay)
        update(\.showViewportBounds, stored.showViewportBounds)
        update(\.showTouchZone, stored.showTouchZone)
        update(\.viewportBoundsColor, stored.viewportBoundsColor)
        update(\.debugLogs, stored.debugLogs)
        update(\.errorReports, stored.errorReports)
        update(\.maxLogFiles, stored.maxLogFiles)
        update(\.cleanupInvalidGames, stored.cleanupInvalidGames)
        update(\.interfaceHaptics, stored.interfaceHaptics)
        update(\.controllerHaptics, stored.controllerHaptics)
        update(\.respectsSilentMode, stored.respectsSilentMode)
        update(\.titlePosition, stored.titlePosition)
        update(\.libraryDisplayMode, stored.libraryDisplayMode)
        update(\.showContinuePlaying, stored.showContinuePlaying)
        update(\.librarySortOption, stored.librarySortOption)
        update(\.rubyGameRunner, stored.rubyGameRunner)
        update(\.disclaimerAcknowledgedVersion, stored.disclaimerAcknowledgedVersion)
        update(\.whatsNewSeenVersion, stored.whatsNewSeenVersion)
        #if os(macOS)
        update(\.quitClosesGamesWithoutAsking, stored.quitClosesGamesWithoutAsking)
        #endif
    }

    @MainActor
    private struct Stored {
        let theme: AppTheme
        let diagnosticsOverlay: Bool
        let showViewportBounds: Bool
        let showTouchZone: Bool
        let viewportBoundsColor: Color
        let debugLogs: Bool
        let errorReports: Bool
        let maxLogFiles: Int
        let cleanupInvalidGames: Bool
        let interfaceHaptics: Bool
        let controllerHaptics: Bool
        let respectsSilentMode: Bool
        let titlePosition: TitlePosition
        let libraryDisplayMode: LibraryDisplayMode
        let showContinuePlaying: Bool
        let librarySortOption: LibrarySortOption
        let rubyGameRunner: GameRunner
        let disclaimerAcknowledgedVersion: Int
        let whatsNewSeenVersion: Int
        #if os(macOS)
        let quitClosesGamesWithoutAsking: Bool
        #endif

        init(_ ud: UserDefaults) {
            let themeRaw = ud.string(forKey: DefaultsKey.theme) ?? AppTheme.auto.rawValue
            theme = AppTheme(rawValue: themeRaw) ?? .auto
            diagnosticsOverlay = ud.bool(forKey: DefaultsKey.debugMode)
            showViewportBounds = ud.bool(forKey: DefaultsKey.showViewportBounds)
            showTouchZone = ud.bool(forKey: DefaultsKey.showTouchZone)
            viewportBoundsColor = AppSettings.loadViewportBoundsColor()
            debugLogs = (ud.object(forKey: DefaultsKey.debugLogs) as? Bool) ?? true
            errorReports = (ud.object(forKey: DefaultsKey.errorReports) as? Bool) ?? true
            let storedMax = ud.integer(forKey: DefaultsKey.maxLogFiles)
            maxLogFiles = storedMax > 0 ? storedMax : 20
            cleanupInvalidGames = ud.bool(forKey: DefaultsKey.cleanupInvalidGames)
            // Haptics default to on. UserDefaults.bool returns false for unset keys.
            interfaceHaptics = ud.object(forKey: DefaultsKey.interfaceHaptics) as? Bool ?? true
            controllerHaptics = ud.object(forKey: DefaultsKey.controllerHaptics) as? Bool ?? true
            respectsSilentMode = ud.bool(forKey: DefaultsKey.respectsSilentMode)
            let raw = ud.string(forKey: DefaultsKey.titlePosition) ?? TitlePosition.inside.rawValue
            titlePosition = TitlePosition(rawValue: raw) ?? .inside
            let modeRaw =
                ud.string(forKey: DefaultsKey.libraryDisplayMode) ?? LibraryDisplayMode.grid.rawValue
            libraryDisplayMode = LibraryDisplayMode(rawValue: modeRaw) ?? .grid
            showContinuePlaying = ud.object(forKey: DefaultsKey.showContinuePlaying) as? Bool ?? true
            let sortRaw =
                ud.string(forKey: DefaultsKey.librarySortOption) ?? LibrarySortOption.titleAZ.rawValue
            librarySortOption = LibrarySortOption(rawValue: sortRaw) ?? .titleAZ
            rubyGameRunner = GameRunner(rawValue: ud.string(forKey: DefaultsKey.rubyGameRunner) ?? "") ?? .app
            disclaimerAcknowledgedVersion = ud.integer(forKey: DefaultsKey.disclaimerAcknowledgedVersion)
            whatsNewSeenVersion = ud.integer(forKey: DefaultsKey.whatsNewSeenVersion)
            #if os(macOS)
            quitClosesGamesWithoutAsking = ud.bool(forKey: DefaultsKey.quitClosesGamesWithoutAsking)
            #endif
        }
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
        #if os(iOS)
        let resolved = UIColor(viewportBoundsColor)
        #else
        let resolved = NSColor(viewportBoundsColor).usingColorSpace(.sRGB) ?? .orange
        #endif
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
        #if os(iOS)
        guard EmpoCoreIsOpen() != 0 else { return }
        gamecore_setShowViewportBounds(showViewportBounds)
        let c = resolvedRGBA()
        gamecore_setViewportBoundsColor(Float(c.r), Float(c.g), Float(c.b), Float(c.a))
        #endif
    }

    func pushSilentModeToCore() {
        #if os(iOS)
        guard EmpoCoreIsOpen() != 0 else { return }
        EmpoCoreSetRespectsSilentMode(respectsSilentMode)
        #endif
    }
}

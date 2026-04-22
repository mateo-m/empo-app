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
    case recentlyPlayed = "recentlyPlayed"
    case leastRecentlyPlayed = "leastRecentlyPlayed"
    case largestSize = "largestSize"
    case smallestSize = "smallestSize"
    case mostPlayed = "mostPlayed"
    case leastPlayed = "leastPlayed"

    var label: String {
        switch self {
        case .titleAZ: "A → Z"
        case .titleZA: "Z → A"
        case .recentlyPlayed: "Recently played"
        case .leastRecentlyPlayed: "Least recently played"
        case .largestSize: "Largest first"
        case .smallestSize: "Smallest first"
        case .mostPlayed: "Most played"
        case .leastPlayed: "Least played"
        }
    }

    var icon: String {
        switch self {
        case .titleAZ: "textformat.abc"
        case .titleZA: "textformat.abc"
        case .recentlyPlayed: "clock"
        case .leastRecentlyPlayed: "clock"
        case .largestSize: "externaldrive"
        case .smallestSize: "externaldrive"
        case .mostPlayed: "hourglass"
        case .leastPlayed: "hourglass"
        }
    }
}

enum TitlePosition: String, CaseIterable {
    case inside = "inside"
    case under  = "under"

    var label: String {
        switch self {
        case .inside: "Inside card"
        case .under:  "Under card"
        }
    }
}

enum AppTheme: String, CaseIterable {
    case dark = "dark"
    case light = "light"
    case auto = "auto"

    var label: String {
        switch self {
        case .dark:  "Dark"
        case .light: "Light"
        case .auto:  "Auto"
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark:  .dark
        case .light: .light
        case .auto:  .unspecified
        }
    }
}


enum ExperimentalFeature: String, CaseIterable, Identifiable {
    case gameQuit = "experimental.gameQuit"
    case gamePause = "experimental.gamePause"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gameQuit:  "Quit game"
        case .gamePause: "Pause game"
        }
    }

    var description: String {
        switch self {
        case .gameQuit:  "Adds a Quit button to the in-game toolbar that returns you to the library."
        case .gamePause: "Adds a Pause button to the in-game toolbar that freezes the game so you can resume it later."
        }
    }
}


@MainActor
@Observable
class AppSettings {
    static let shared = AppSettings()

    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: DefaultsKey.theme) }
    }

    var debugMode: Bool {
        didSet { UserDefaults.standard.set(debugMode, forKey: DefaultsKey.debugMode) }
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
        didSet { UserDefaults.standard.set(libraryDisplayMode.rawValue, forKey: DefaultsKey.libraryDisplayMode) }
    }

    var showContinuePlaying: Bool {
        didSet { UserDefaults.standard.set(showContinuePlaying, forKey: DefaultsKey.showContinuePlaying) }
    }

    var librarySortOption: LibrarySortOption {
        didSet { UserDefaults.standard.set(librarySortOption.rawValue, forKey: DefaultsKey.librarySortOption) }
    }

    // MARK: - Splash disclaimer acknowledgment

    /// Monotonically increasing version so the flow can re-prompt when the
    /// disclaimer copy changes meaningfully.
    static let currentDisclaimerVersion = 1

    var disclaimerAcknowledgedVersion: Int {
        didSet { UserDefaults.standard.set(disclaimerAcknowledgedVersion, forKey: DefaultsKey.disclaimerAcknowledgedVersion) }
    }

    var needsDisclaimer: Bool {
        disclaimerAcknowledgedVersion < Self.currentDisclaimerVersion
    }

    func acknowledgeDisclaimer() {
        disclaimerAcknowledgedVersion = Self.currentDisclaimerVersion
    }

    private var experimentalFlags: [String: Bool] {
        didSet {
            for (key, value) in experimentalFlags {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    private init() {
        let ud = UserDefaults.standard
        let themeRaw = ud.string(forKey: DefaultsKey.theme) ?? AppTheme.auto.rawValue
        self.theme = AppTheme(rawValue: themeRaw) ?? .auto
        self.debugMode = ud.bool(forKey: DefaultsKey.debugMode)
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

        var flags: [String: Bool] = [:]
        for feature in ExperimentalFeature.allCases {
            flags[feature.rawValue] = ud.bool(forKey: feature.rawValue)
        }
        self.experimentalFlags = flags

        mkxp_setShowViewportBounds(showViewportBounds)
        pushViewportBoundsColor()
    }


    func isEnabled(_ feature: ExperimentalFeature) -> Bool {
        experimentalFlags[feature.rawValue] ?? false
    }

    func setEnabled(_ feature: ExperimentalFeature, _ value: Bool) {
        experimentalFlags[feature.rawValue] = value
    }


    private static let defaultViewportBoundsColor = Color(.sRGB, red: 1.0, green: 0.584, blue: 0.0, opacity: 0.5)

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
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
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

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


enum RendererOption: String, CaseIterable {
    case openGLES = "opengles"
    case angle = "angle"

    var label: String {
        switch self {
        case .openGLES: "OpenGL ES"
        case .angle: "ANGLE"
        }
    }

    /// When true, the settings UI shows a "BETA" tag next to the picker's
    /// label while this option is selected. Keeps the picker entries
    /// terse (no "(Beta)" suffix in the menu) while still signaling the
    /// stability status to the user once they've committed.
    var isBeta: Bool {
        switch self {
        case .openGLES: false
        case .angle:    true
        }
    }
}


enum ExperimentalFeature: String, CaseIterable, Identifiable {
    case gameQuit = "experimental.gameQuit"
    case gamePause = "experimental.gamePause"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gameQuit: "Quit game"
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

    private(set) var launchedRenderer: RendererOption

    var rendererPendingRestart: Bool {
        renderer != launchedRenderer
    }

    func syncRendererWithEngine() {
        let current = mkxp_getCurrentRenderer()
        launchedRenderer = current == MKXP_RENDERER_ANGLE ? .angle : .openGLES
    }

    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    var debugMode: Bool {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
    }

    var showViewportBounds: Bool {
        didSet {
            UserDefaults.standard.set(showViewportBounds, forKey: "showViewportBounds")
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
        didSet { UserDefaults.standard.set(debugLogs, forKey: "debugLogs") }
    }

    var maxLogFiles: Int {
        didSet { UserDefaults.standard.set(maxLogFiles, forKey: "maxLogFiles") }
    }

    var cleanupInvalidGames: Bool {
        didSet { UserDefaults.standard.set(cleanupInvalidGames, forKey: "cleanupInvalidGames") }
    }

    var interfaceHaptics: Bool {
        didSet { UserDefaults.standard.set(interfaceHaptics, forKey: "interfaceHaptics") }
    }

    var controllerHaptics: Bool {
        didSet { UserDefaults.standard.set(controllerHaptics, forKey: "controllerHaptics") }
    }

    var titlePosition: TitlePosition {
        didSet { UserDefaults.standard.set(titlePosition.rawValue, forKey: "titlePosition") }
    }

    var libraryDisplayMode: LibraryDisplayMode {
        didSet { UserDefaults.standard.set(libraryDisplayMode.rawValue, forKey: "libraryDisplayMode") }
    }

    var showContinuePlaying: Bool {
        didSet { UserDefaults.standard.set(showContinuePlaying, forKey: "showContinuePlaying") }
    }

    var librarySortOption: LibrarySortOption {
        didSet { UserDefaults.standard.set(librarySortOption.rawValue, forKey: "librarySortOption") }
    }

    var renderer: RendererOption {
        didSet { UserDefaults.standard.set(renderer.rawValue, forKey: "renderer") }
    }

    // MARK: - Splash disclaimer acknowledgment
    //
    // The app is in early development and carries known instability. We
    // show a first-launch disclaimer over the splash that the user must
    // acknowledge to continue. The stored value is a monotonically
    // increasing version so we can re-prompt when the disclaimer copy
    // changes in a meaningful way (e.g., after a big architectural
    // shift or a new class of known-broken games).
    static let currentDisclaimerVersion = 1

    var disclaimerAcknowledgedVersion: Int {
        didSet { UserDefaults.standard.set(disclaimerAcknowledgedVersion, forKey: "disclaimerAcknowledgedVersion") }
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
        let themeRaw = UserDefaults.standard.string(forKey: "theme") ?? AppTheme.dark.rawValue
        self.theme = AppTheme(rawValue: themeRaw) ?? .dark
        self.debugMode = UserDefaults.standard.bool(forKey: "debugMode")
        self.showViewportBounds = UserDefaults.standard.bool(forKey: "showViewportBounds")
        self.viewportBoundsColor = Self.loadViewportBoundsColor()
        self.debugLogs = UserDefaults.standard.bool(forKey: "debugLogs")
        let storedMax = UserDefaults.standard.integer(forKey: "maxLogFiles")
        self.maxLogFiles = storedMax > 0 ? storedMax : 20
        self.cleanupInvalidGames = UserDefaults.standard.bool(forKey: "cleanupInvalidGames")
        // Haptics default to on — UserDefaults.bool returns false for unset keys
        self.interfaceHaptics = UserDefaults.standard.object(forKey: "interfaceHaptics") as? Bool ?? true
        self.controllerHaptics = UserDefaults.standard.object(forKey: "controllerHaptics") as? Bool ?? true
        let raw = UserDefaults.standard.string(forKey: "titlePosition") ?? TitlePosition.inside.rawValue
        self.titlePosition = TitlePosition(rawValue: raw) ?? .inside
        let modeRaw = UserDefaults.standard.string(forKey: "libraryDisplayMode") ?? LibraryDisplayMode.grid.rawValue
        self.libraryDisplayMode = LibraryDisplayMode(rawValue: modeRaw) ?? .grid
        self.showContinuePlaying = UserDefaults.standard.object(forKey: "showContinuePlaying") as? Bool ?? true
        let sortRaw = UserDefaults.standard.string(forKey: "librarySortOption") ?? LibrarySortOption.titleAZ.rawValue
        self.librarySortOption = LibrarySortOption(rawValue: sortRaw) ?? .titleAZ
        let rendererRaw = UserDefaults.standard.string(forKey: "renderer") ?? RendererOption.openGLES.rawValue
        let resolved = RendererOption(rawValue: rendererRaw) ?? .openGLES
        self.renderer = resolved
        self.launchedRenderer = resolved
        self.disclaimerAcknowledgedVersion = UserDefaults.standard.integer(forKey: "disclaimerAcknowledgedVersion")

        var flags: [String: Bool] = [:]
        for feature in ExperimentalFeature.allCases {
            flags[feature.rawValue] = UserDefaults.standard.bool(forKey: feature.rawValue)
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
        guard ud.object(forKey: "vpBoundsR") != nil else { return defaultViewportBoundsColor }
        return Color(
            .sRGB,
            red: ud.double(forKey: "vpBoundsR"),
            green: ud.double(forKey: "vpBoundsG"),
            blue: ud.double(forKey: "vpBoundsB"),
            opacity: ud.double(forKey: "vpBoundsA")
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
        ud.set(Double(c.r), forKey: "vpBoundsR")
        ud.set(Double(c.g), forKey: "vpBoundsG")
        ud.set(Double(c.b), forKey: "vpBoundsB")
        ud.set(Double(c.a), forKey: "vpBoundsA")
    }

    func pushViewportBoundsColor() {
        let c = resolvedRGBA()
        mkxp_setViewportBoundsColor(Float(c.r), Float(c.g), Float(c.b), Float(c.a))
    }
}

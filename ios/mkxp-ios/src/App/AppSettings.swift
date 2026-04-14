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

// MARK: - Experimental Features

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
        case .gameQuit: "Quit the running game and return to the library."
        case .gamePause: "Pause the engine and freeze the game in place."
        }
    }
}

// MARK: - App Settings

@MainActor
@Observable
class AppSettings {
    static let shared = AppSettings()

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

    /// Backing store for experimental feature toggles.
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
        // Haptics default to on
        self.interfaceHaptics = UserDefaults.standard.object(forKey: "interfaceHaptics") as? Bool ?? true
        self.controllerHaptics = UserDefaults.standard.object(forKey: "controllerHaptics") as? Bool ?? true
        let raw = UserDefaults.standard.string(forKey: "titlePosition") ?? TitlePosition.inside.rawValue
        self.titlePosition = TitlePosition(rawValue: raw) ?? .inside
        let modeRaw = UserDefaults.standard.string(forKey: "libraryDisplayMode") ?? LibraryDisplayMode.grid.rawValue
        self.libraryDisplayMode = LibraryDisplayMode(rawValue: modeRaw) ?? .grid

        var flags: [String: Bool] = [:]
        for feature in ExperimentalFeature.allCases {
            flags[feature.rawValue] = UserDefaults.standard.bool(forKey: feature.rawValue)
        }
        self.experimentalFlags = flags

        // Push initial values to bridge
        mkxp_setShowViewportBounds(showViewportBounds)
        pushViewportBoundsColor()
    }

    // MARK: - Experimental API

    func isEnabled(_ feature: ExperimentalFeature) -> Bool {
        experimentalFlags[feature.rawValue] ?? false
    }

    func setEnabled(_ feature: ExperimentalFeature, _ value: Bool) {
        experimentalFlags[feature.rawValue] = value
    }

    // MARK: - Viewport Bounds Color

    /// Default: orange at 50% opacity
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

    private func saveViewportBoundsColor() {
        let resolved = UIColor(viewportBoundsColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ud = UserDefaults.standard
        ud.set(Double(r), forKey: "vpBoundsR")
        ud.set(Double(g), forKey: "vpBoundsG")
        ud.set(Double(b), forKey: "vpBoundsB")
        ud.set(Double(a), forKey: "vpBoundsA")
    }

    func pushViewportBoundsColor() {
        let resolved = UIColor(viewportBoundsColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        mkxp_setViewportBoundsColor(Float(r), Float(g), Float(b), Float(a))
    }
}

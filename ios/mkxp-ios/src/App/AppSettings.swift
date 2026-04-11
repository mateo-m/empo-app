import Foundation
import Observation

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

@Observable
class AppSettings {
    static let shared = AppSettings()

    var debugMode: Bool {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
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

    var titlePosition: TitlePosition {
        didSet { UserDefaults.standard.set(titlePosition.rawValue, forKey: "titlePosition") }
    }

    private init() {
        self.debugMode = UserDefaults.standard.bool(forKey: "debugMode")
        self.debugLogs = UserDefaults.standard.bool(forKey: "debugLogs")
        let storedMax = UserDefaults.standard.integer(forKey: "maxLogFiles")
        self.maxLogFiles = storedMax > 0 ? storedMax : 20
        self.cleanupInvalidGames = UserDefaults.standard.bool(forKey: "cleanupInvalidGames")
        let raw = UserDefaults.standard.string(forKey: "titlePosition") ?? TitlePosition.inside.rawValue
        self.titlePosition = TitlePosition(rawValue: raw) ?? .inside
    }
}

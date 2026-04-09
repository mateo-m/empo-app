import Foundation

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var debugMode: Bool {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
    }

    private init() {
        self.debugMode = UserDefaults.standard.bool(forKey: "debugMode")
    }
}

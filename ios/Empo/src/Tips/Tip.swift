import Foundation
import Observation


struct Tip: Identifiable {
    let id: String
    let excerpt: String
    let description: String?
    let dismissal: DismissalPolicy

    enum DismissalPolicy: Equatable {
        /// Tip cannot be dismissed by the user.
        case none
        /// Once dismissed, never shown again.
        case permanent
        /// Reappears after `interval` seconds since dismissal.
        case temporary(interval: TimeInterval)
    }

    var isDismissable: Bool { dismissal != .none }
    var hasDetail: Bool { description != nil }
}


// MARK: - Tip definitions

extension Tip {
    static let gameInfoCustomization = Tip(
        id: "gameInfo.customization",
        excerpt: "Tap the artwork, banner, or title to customize them.",
        description: nil,
        dismissal: .permanent
    )
}


// MARK: - Persistence

@MainActor
@Observable
final class TipStore {
    static let shared = TipStore()

    private var dismissedAt: [String: Date]

    private init() {
        var loaded: [String: Date] = [:]
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        let prefix = DefaultsKey.tipDismissedPrefix
        for key in allKeys where key.hasPrefix(prefix) {
            let tipID = String(key.dropFirst(prefix.count))
            if let timestamp = defaults.object(forKey: key) as? Double {
                loaded[tipID] = Date(timeIntervalSince1970: timestamp)
            }
        }
        self.dismissedAt = loaded
    }

    func isVisible(_ tip: Tip) -> Bool {
        guard let date = dismissedAt[tip.id] else { return true }
        switch tip.dismissal {
        case .none:
            return true
        case .permanent:
            return false
        case .temporary(let interval):
            return Date().timeIntervalSince(date) >= interval
        }
    }

    func dismiss(_ tip: Tip) {
        guard tip.isDismissable else { return }
        let now = Date()
        dismissedAt[tip.id] = now
        UserDefaults.standard.set(
            now.timeIntervalSince1970,
            forKey: DefaultsKey.tipDismissed(tipID: tip.id)
        )
    }
}

import Foundation
import Observation

/// In-app discoverability hint shown via `HintBanner`. Examples: a
/// one-time pointer to a UI affordance the user might miss
/// otherwise (e.g. "tap the artwork to customize").
///
/// Not related to App Store / StoreKit "tipping" or donations -
/// this is purely a UI hint system, persisted via UserDefaults.
struct Hint: Identifiable {
    let id: String
    let excerpt: String
    let description: String?
    let dismissal: DismissalPolicy
    /// SF Symbol shown in the leading slot of `HintBanner`. Defaults
    /// to the design-system "tip" icon (a filled lightbulb); hints
    /// signaling action needed (e.g. "restart this game") can opt
    /// into a more directional symbol while keeping the same brand
    /// colored pill visual.
    let icon: String

    init(
        id: String,
        excerpt: String,
        description: String? = nil,
        dismissal: DismissalPolicy,
        icon: String = "lightbulb.fill"
    ) {
        self.id = id
        self.excerpt = excerpt
        self.description = description
        self.dismissal = dismissal
        self.icon = icon
    }

    enum DismissalPolicy: Equatable {
        /// Hint cannot be dismissed by the user.
        case none
        /// Once dismissed, never shown again.
        case permanent
        /// Reappears after `interval` seconds since dismissal.
        case temporary(interval: TimeInterval)
    }

    var isDismissable: Bool { dismissal != .none }
    var hasDetail: Bool { description != nil }
}

// MARK: - Hint definitions

extension Hint {
    static let gameInfoCustomization = Hint(
        id: "gameInfo.customization",
        excerpt: "Tap the artwork, banner, or title to customize them.",
        description: nil,
        dismissal: .permanent
    )
}

// MARK: - Persistence

@MainActor
@Observable
final class HintStore {
    static let shared = HintStore()

    private var dismissedAt: [String: Date]

    private init() {
        var loaded: [String: Date] = [:]
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        let prefix = DefaultsKey.hintDismissedPrefix
        for key in allKeys where key.hasPrefix(prefix) {
            let hintID = String(key.dropFirst(prefix.count))
            if let timestamp = defaults.object(forKey: key) as? Double {
                loaded[hintID] = Date(timeIntervalSince1970: timestamp)
            }
        }
        self.dismissedAt = loaded
    }

    func isVisible(_ hint: Hint) -> Bool {
        guard let date = dismissedAt[hint.id] else { return true }
        switch hint.dismissal {
        case .none:
            return true
        case .permanent:
            return false
        case .temporary(let interval):
            return Date().timeIntervalSince(date) >= interval
        }
    }

    func dismiss(_ hint: Hint) {
        guard hint.isDismissable else { return }
        let now = Date()
        dismissedAt[hint.id] = now
        UserDefaults.standard.set(
            now.timeIntervalSince1970,
            forKey: DefaultsKey.hintDismissed(hintID: hint.id)
        )
    }
}

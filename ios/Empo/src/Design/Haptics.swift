import UIKit

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    // Read from the in-memory AppSettings instead of UserDefaults so
    // every button press doesn't pay for a disk-backed lookup. The
    // AppSettings singleton is @MainActor-isolated; we assume
    // isolation here because all haptic call sites are already main.
    @MainActor
    private static var interfaceEnabled: Bool {
        AppSettings.shared.interfaceHaptics
    }

    @MainActor
    static func tap() {
        guard interfaceEnabled else { return }
        light.impactOccurred()
    }

    @MainActor
    static func impact() {
        guard interfaceEnabled else { return }
        medium.impactOccurred()
    }

    @MainActor
    static func success() {
        guard interfaceEnabled else { return }
        notification.notificationOccurred(.success)
    }

}

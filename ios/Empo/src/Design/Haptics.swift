import UIKit

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    // Read the in-memory AppSettings, not UserDefaults. This keeps a
    // button press free of a disk-backed lookup. The AppSettings
    // singleton is @MainActor-isolated. This code assumes main-actor
    // isolation because all haptic call sites already run on main.
    @MainActor
    private static var interfaceEnabled: Bool {
        AppSettings.shared.interfaceHaptics
    }

    /// A separate user setting gates haptics on the in-game controls
    /// (D-pad, action buttons). Some players find constant buzzing
    /// during gameplay distracting but still want taps elsewhere in
    /// the UI.
    @MainActor
    private static var controllerEnabled: Bool {
        AppSettings.shared.controllerHaptics
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

    /// A soft tap for when an on-screen game control engages
    /// (action button press, D-pad direction enter). The
    /// `controllerHaptics` setting gates it. That setting is
    /// independent of the interface haptics toggle.
    @MainActor
    static func controllerTap() {
        guard controllerEnabled else { return }
        light.impactOccurred()
    }

}

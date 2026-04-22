import UIKit

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    // Read from the in-memory AppSettings instead of UserDefaults so
    // every button press doesn't pay for a disk-backed lookup. The
    // AppSettings singleton is @MainActor-isolated; the haptics site assumes
    // isolation here because all haptic call sites are already main.
    @MainActor
    private static var interfaceEnabled: Bool {
        AppSettings.shared.interfaceHaptics
    }

    /// Haptics on in-game controls (D-pad, action buttons) are gated
    /// on a separate user setting because some players find constant
    /// buzzing during gameplay distracting while still wanting taps
    /// elsewhere in the UI.
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

    /// Soft tap emitted when an on-screen game control engages
    /// (action button press, D-pad direction enter). Gated on the
    /// `controllerHaptics` setting, which is independent of the
    /// interface haptics toggle.
    @MainActor
    static func controllerTap() {
        guard controllerEnabled else { return }
        light.impactOccurred()
    }

}

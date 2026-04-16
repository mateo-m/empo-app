import UIKit

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    private static var interfaceEnabled: Bool {
        UserDefaults.standard.object(forKey: "interfaceHaptics") as? Bool ?? true
    }

    static func tap() {
        guard interfaceEnabled else { return }
        light.impactOccurred()
    }

    static func impact() {
        guard interfaceEnabled else { return }
        medium.impactOccurred()
    }

    static func success() {
        guard interfaceEnabled else { return }
        notification.notificationOccurred(.success)
    }

}

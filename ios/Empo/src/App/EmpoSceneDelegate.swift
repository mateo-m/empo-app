import UIKit

/// Adopts the UIScene lifecycle that the iOS 27 SDK requires.
/// SDL still owns the game window. This delegate only boots Empo's SwiftUI shell
/// once UIKit has connected a `UIWindowScene`.
@objc(EmpoSceneDelegate)
final class EmpoSceneDelegate: UIResponder, UIWindowSceneDelegate {

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        AppWindow.install(in: windowScene)
        // The backup schedule of SPEC 7. It watches the app lifetime,
        // so it starts once the scene connects.
        BackupScheduler.shared.start()
    }
}

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

    /// Takes the OAuth callback of SPEC 8.10.
    ///
    /// The callback is a custom URL scheme, because an https link
    /// needs the Associated Domains entitlement and a sideloaded
    /// build does not hold it.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for context in contexts where DropboxSignIn.shared.resume(with: context.url) {
            return
        }
    }
}

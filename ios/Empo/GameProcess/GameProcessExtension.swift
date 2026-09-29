import ExtensionFoundation
import ExtensionKit
import SwiftUI

/// The process one game runs in. Empo starts a new one for each game
/// and ends it when the player quits, so no state of a game, such as
/// its Ruby VM, reaches the next one.
///
/// The core draws in windows of its own, which UIKit puts in this
/// scene, over the black view.
@main
final class GameProcessExtension: AppExtension {
    required init() {}

    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(
            PrimitiveAppExtensionScene(id: "game") {
                Color.black.ignoresSafeArea()
            } onConnection: { connection in
                EmpoGameProcessAccept(connection)
            }
        )
    }
}

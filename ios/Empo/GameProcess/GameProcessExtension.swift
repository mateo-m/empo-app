import ExtensionFoundation
import ExtensionKit
import SwiftUI

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

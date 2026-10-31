// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

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
                    .onGeometryChange(for: Bool.self) {
                        $0.size.width > 0 && $0.size.height > 0
                    } action: { hasSize in
                        if hasSize {
                            EmpoGameProcessSceneHasSize()
                        }
                    }
            } onConnection: { connection in
                EmpoGameProcessAccept(connection)
            }
        )
    }
}

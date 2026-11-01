// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI

@main
struct EmpoMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: EmpoMacAppDelegate
    @State private var settings = AppSettings.shared

    var body: some Scene {
        Window(AppInfo.name, id: "library") {
            LibraryWindow()
                .frame(minWidth: 720, minHeight: 480)
                .environment(\.appSettings, settings)
                .environment(\.gameLibrary, GameLibrary.shared)
                .onChange(of: settings.theme, initial: true) { applyTheme(settings.theme) }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            LibraryCommands()
            InspectorCommands()
        }

        WindowGroup("Game Settings", id: GameSettingsWindow.id, for: String.self) { $gameID in
            if let gameID {
                GameSettingsWindow(gameID: gameID)
                    .environment(\.appSettings, settings)
            }
        }
        .defaultSize(width: 520, height: 640)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Settings {
            MacSettingsView()
                .environment(\.appSettings, settings)
        }
    }

    private func applyTheme(_ theme: AppTheme) {
        NSApp.appearance =
            switch theme {
            case .dark: NSAppearance(named: .darkAqua)
            case .light: NSAppearance(named: .aqua)
            case .auto: nil
            }
    }
}

final class EmpoMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        GameLauncher.shared.confirmQuit()
    }
}

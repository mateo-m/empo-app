// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI

@main
struct EmpoMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: EmpoMacAppDelegate
    @State private var settings = AppSettings.shared

    init() {
        if CommandLine.arguments.contains(GameLauncher.checkCoresArgument) {
            exit(GameLauncher.checkCores() ? 0 : 1)
        }
    }

    var body: some Scene {
        Window(AppInfo.name, id: "library") {
            LibraryWindow()
                .frame(minWidth: 720, minHeight: 480)
                .environment(\.appSettings, settings)
                .environment(\.gameLibrary, GameLibrary.shared)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            AboutCommand()
            LibraryCommands()
            InspectorCommands()
            HelpCommands()
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

        Window("Game Cores", id: HelpCommands.gameCoresWindowID) {
            NavigationStack { GameCoresView() }
                .frame(minWidth: 420, minHeight: 360)
                .tint(.brand)
        }
        .defaultSize(width: 520, height: 560)
        .restorationBehavior(.disabled)

        Window("Open-Source Licenses", id: HelpCommands.licensesWindowID) {
            NavigationStack { LicensesView() }
                .frame(minWidth: 420, minHeight: 360)
                .tint(.brand)
        }
        .defaultSize(width: 560, height: 640)
        .restorationBehavior(.disabled)

        Settings {
            MacSettingsView()
                .environment(\.appSettings, settings)
        }
    }
}

private struct AboutCommand: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppInfo.name)") {
                NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
            }
            if UpdateChecker.isSideloadBuild {
                Button("Check for Updates…") {
                    Task { await MacUpdates.shared.checkNow() }
                }
            }
        }
    }

    private var credits: NSAttributedString {
        let text = NSMutableAttributedString(
            string: String(localized: "Made with ☕ by Mateo M."),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    return style
                }(),
            ]
        )
        let name = (text.string as NSString).range(of: "Mateo M.")
        if name.location != NSNotFound {
            text.addAttribute(.link, value: URL(string: "https://github.com/mateo-m")!, range: name)
        }
        return text
    }
}

private struct HelpCommands: Commands {
    static let gameCoresWindowID = "game-cores"
    static let licensesWindowID = "licenses"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Link("\(AppInfo.name) Support", destination: EmpoLink.support)
            Divider()
            Link("Privacy Policy", destination: EmpoLink.privacy)
            Link("Terms of Use", destination: EmpoLink.terms)
            Link("Source Code on GitHub", destination: EmpoLink.sourceCode)
            Divider()
            Button("Game Cores") { openWindow(id: Self.gameCoresWindowID) }
            Button("Open-Source Licenses") { openWindow(id: Self.licensesWindowID) }
        }
    }
}

final class EmpoMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Each game reads the newest file when it starts.
        CABundleStore.refreshIfStale {}
        Task { await MacUpdates.shared.checkIfStale() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        GameLauncher.shared.confirmQuit()
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI

struct MacSettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Controller", systemImage: "gamecontroller") {
                ControllerButtonsForm(game: nil).frame(height: 560)
            }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .frame(width: 540)
        .tint(.brand)
    }
}

private struct GeneralSettings: View {
    @Environment(\.appSettings) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SettingsToggle(
                    title: "Ask before closing games",
                    isOn: Binding(
                        get: { !settings.quitClosesGamesWithoutAsking },
                        set: { settings.quitClosesGamesWithoutAsking = !$0 }
                    ),
                    description: "When you quit \(AppInfo.name) with games open, ask first."
                )
            }
            Section {
                MidiSoundSetRow()
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AdvancedSettings: View {
    @Environment(\.appSettings) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SettingsToggle(
                    title: "Delete broken imports",
                    isOn: $settings.cleanupInvalidGames,
                    description:
                        "Deletes games that failed to import the next time you open \(AppInfo.name). You can't undo this."
                )
                SettingsToggle(
                    title: "Send error reports",
                    isOn: $settings.errorReports,
                    description:
                        "When a game shows an error or crashes, \(AppInfo.name) sends the error and the game's log to me, so I can fix it."
                )
                SettingsToggle(
                    title: "Debug logs",
                    isOn: $settings.debugLogs,
                    description: "Saves a log for each play session."
                )
                if settings.debugLogs {
                    Stepper(value: $settings.maxLogFiles, in: 5...100, step: 5) {
                        Text("Keep last \(settings.maxLogFiles) logs per game")
                        Text("\(AppInfo.name) deletes older logs each time you start a game.")
                    }
                }
            } footer: {
                Text("Use these if a game misbehaves or you want to report a bug.")
            }

            Section {
                LabeledContent {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([DataDirectory.documentsRootURL])
                    }
                } label: {
                    Text("Files")
                    Text("Your games, saves, and logs are in this folder.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

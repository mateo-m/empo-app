// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI

struct MacSettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettings: View {
    @Environment(\.appSettings) private var settings
    @AppStorage(DefaultsKey.quitClosesGamesWithoutAsking) private var quitWithoutAsking = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                Picker("Layout", selection: $settings.libraryDisplayMode) {
                    ForEach(LibraryDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }
            Section {
                SettingsToggle(
                    title: "Ask before closing games",
                    isOn: Binding(get: { !quitWithoutAsking }, set: { quitWithoutAsking = !$0 }),
                    description: "When you quit \(AppInfo.name) with games open, ask first."
                )
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
                    title: "Debug logs",
                    isOn: $settings.debugLogs,
                    description: "Saves a log for each play session."
                )
                if settings.debugLogs {
                    Stepper(
                        "Keep last \(settings.maxLogFiles) logs per game",
                        value: $settings.maxLogFiles, in: 5...100, step: 5)
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

private struct AboutSettings: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: Spacing.md) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 96, height: 96)
                        Text(AppInfo.name)
                            .font(.title.weight(.bold))
                        Text("Version \(AppInfo.version)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                }

                Section {
                    NavigationLink("Game cores") { GameCoresView() }
                    NavigationLink("Open-source licenses") { LicensesView() }
                }

                Section {
                    ExternalLink(
                        "Privacy policy", systemImage: "hand.raised", url: "https://empo.mateo.sh/privacy/")
                    ExternalLink("Terms of use", systemImage: "scale.3d", url: "https://empo.mateo.sh/terms/")
                    ExternalLink(
                        "Source code on GitHub", image: Image(.gitHubMark),
                        url: "https://github.com/mateo-m/empo-app")
                    ExternalLink(
                        "Find me on Twitter", image: Image(.twitterMark), url: "https://x.com/gridplay_")
                }
            }
            .formStyle(.grouped)
        }
        .frame(height: 520)
    }
}

private struct ExternalLink: View {
    let title: LocalizedStringKey
    let icon: Image
    let url: URL

    init(_ title: LocalizedStringKey, systemImage: String, url: String) {
        self.init(title, image: Image(systemName: systemImage), url: url)
    }

    init(_ title: LocalizedStringKey, image: Image, url: String) {
        self.title = title
        self.icon = image
        self.url = URL(string: url)!
    }

    var body: some View {
        Link(destination: url) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    icon
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

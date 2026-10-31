// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct ExperimentalSection: View {
    @Environment(\.appSettings) private var settings

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SettingsToggle(
                    title: "Quit and switch games",
                    isOn: Binding(
                        get: { settings.rubyGameRunner == .gameProcess },
                        set: { settings.rubyGameRunner = $0 ? .gameProcess : .app }
                    ),
                    description:
                        "Quit a game and start another one without closing \(AppInfo.name). Works with \(GameCores.gameProcessGamesName)."
                )
                if settings.rubyGameRunner == .gameProcess, DataDirectory.unmovedItem != nil {
                    Label(
                        "Couldn't move your games and saves, so this setting isn't on yet. Your files didn't change. \(AppInfo.name) tries again each time you open it.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.warning)
                    .transition(.opacity)
                } else if settings.rubyGameRunner != AppSettings.rubyGameRunnerThisLaunch {
                    Label(
                        "Close \(AppInfo.name) from the app switcher and open it again to apply this change.",
                        systemImage: "arrow.clockwise"
                    )
                    .font(.footnote)
                    .foregroundStyle(.warning)
                    .transition(.opacity)
                }
            }
            .labelStyle(IconOnFirstLineLabelStyle())
            // A List row that grows in an animation keeps its old height
            // for the text above the new line, and cuts it to one line.
            .fixedSize(horizontal: false, vertical: true)
            .animation(Motion.snappy, value: settings.rubyGameRunner)
        } header: {
            Text("Experimental")
        } footer: {
            Text(
                "These features are still in testing. If a game stops or doesn't start, turn on Debug logs and play it again. Then share its report from the game's Info and attach it to a GitHub issue."
            )
        }
    }
}

private struct IconOnFirstLineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            configuration.icon
            configuration.title
        }
    }
}

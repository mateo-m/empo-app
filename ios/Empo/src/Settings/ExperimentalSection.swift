import SwiftUI

/// Features in testing. Shown only in a build with a core in
/// `GameCores.gameProcessCores`, because the one feature here is the
/// game process for those cores.
struct ExperimentalSection: View {
    @Environment(\.appSettings) private var settings

    private let isAvailable = AppSettings.gameProcessIsAvailable

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SettingsToggle(
                    title: "Quit and switch games",
                    isOn: Binding(
                        get: { isAvailable && settings.rubyGameRunner == .gameProcess },
                        set: { settings.rubyGameRunner = $0 ? .gameProcess : .app }
                    ),
                    description:
                        "Quit a game and start another one without closing \(AppInfo.name). Works with \(GameCores.gameProcessGamesName)."
                )
                .disabled(!isAvailable)
                if !isAvailable {
                    Label(
                        "Not available. The tool that installed \(AppInfo.name) left out a part that this feature needs.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                "These features are still in testing. If a game stops or doesn't start, share its report from the game's Info and attach it to a GitHub issue."
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

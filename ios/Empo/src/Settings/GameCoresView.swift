import SwiftUI

struct GameCoresView: View {
    private let cores = GameCores.inThisBuild

    private var tools: [(key: String, value: [any GameCore])] {
        Dictionary(grouping: cores, by: \.madeWith).sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            Section {
                if cores.isEmpty {
                    Text("This build has no game core.")
                        .foregroundStyle(.secondary)
                }

                ForEach(tools, id: \.key) { tool, cores in
                    DisclosureGroup(tool) {
                        ForEach(cores, id: \.framework) { core in
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(core.displayName)
                                Text(core.gamesLine)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                // `.font(.caption)` plus `.fontDesign(.monospaced)`
                                // renders rounded under RootView's app-wide
                                // `.fontDesign(.rounded)`. A point size keeps it.
                                Text("Built from \(core.version)")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, Spacing.xxs)
                        }
                    }
                }
            } footer: {
                Text(
                    "A core runs the games in its list. Empo opens the core a game needs when you start the game."
                )
            }
        }
        .navigationTitle("Game cores")
        .navigationBarTitleDisplayMode(.inline)
    }
}

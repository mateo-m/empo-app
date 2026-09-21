import SwiftUI

struct GameCoresView: View {
    private let cores = BuiltInGameCore.all

    var body: some View {
        List {
            Section {
                if cores.isEmpty {
                    Text("This build has no game core.")
                        .foregroundStyle(.secondary)
                }

                ForEach(cores) { core in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(core.displayName)
                        Text(core.games)
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

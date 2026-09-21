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
                        Text(core.name)
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

struct BuiltInGameCore: Identifiable {
    let id: String
    let name: String
    let games: String
    let version: String

    /// EngineSessionCoordinator.openCore dlopens the binary inside the
    /// framework, so a core is part of the build only when that binary is
    /// there. The two build-framework-ios.sh scripts write EmpoCoreVersion.
    static let all: [BuiltInGameCore] = [
        ("MkxpCore", "RPG Maker core", "Runs RPG Maker XP, VX and VX Ace games"),
        ("PsdkCore", "Pokémon SDK core", "Runs Pokémon SDK games"),
    ].compactMap { framework, name, games in
        guard
            let bundle = Bundle.main.privateFrameworksURL?
                .appendingPathComponent("\(framework).framework"),
            FileManager.default.fileExists(
                atPath: bundle.appendingPathComponent(framework).path)
        else {
            return nil
        }
        let version =
            Bundle(url: bundle)?.object(forInfoDictionaryKey: "EmpoCoreVersion") as? String
        return BuiltInGameCore(
            id: framework, name: name, games: games, version: version ?? "unknown")
    }
}

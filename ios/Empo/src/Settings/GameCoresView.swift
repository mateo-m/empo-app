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

    static let all: [BuiltInGameCore] = [
        read("MkxpCore", name: "RPG Maker core", games: rpgMakerGames),
        read("PsdkCore", name: "Pokemon SDK core", games: "Runs Pokemon SDK games"),
    ].compactMap { $0 }

    /// EngineSessionCoordinator.openCore dlopens the binary inside the
    /// framework, so a core is part of the build only when that binary is
    /// there.
    private static func frameworkBundle(_ framework: String) -> Bundle? {
        guard
            let url = Bundle.main.privateFrameworksURL?
                .appendingPathComponent("\(framework).framework"),
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent(framework).path)
        else {
            return nil
        }
        return Bundle(url: url)
    }

    /// The two build-framework-ios.sh scripts write EmpoCoreVersion.
    private static func read(
        _ framework: String, name: String, games: String
    )
        -> BuiltInGameCore?
    {
        guard let bundle = frameworkBundle(framework) else { return nil }
        let version = bundle.object(forInfoDictionaryKey: "EmpoCoreVersion") as? String
        return BuiltInGameCore(
            id: framework, name: name, games: games, version: version ?? "unknown")
    }

    /// GameImportValidator refuses a game the mask does not cover, so this
    /// line follows the mask. check-mkxp-framework.sh allows 3, which is
    /// RGSS1 and RGSS2, and 7, which adds RGSS3.
    private static var rpgMakerGames: String {
        let mask =
            frameworkBundle("MkxpCore")?
            .object(forInfoDictionaryKey: "EmpoCoreRGSSVersionMask") as? Int
        return mask == 7
            ? "Runs RPG Maker XP, VX and VX Ace games"
            : "Runs RPG Maker XP and VX games"
    }
}

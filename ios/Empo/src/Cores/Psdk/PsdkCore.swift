import Foundation
import GameProbe
import SwiftUI

/// The PSDK core carries one Ruby for each version that Pokémon Studio
/// compiles a release with, and a Ruby can load only bytecode of its own
/// version. `launch` picks the Ruby for the game.
struct PsdkCore: GameCore {
    let framework = "PsdkCore"
    let symbolPrefix = "psdk_"
    let displayName = "PSDK core"
    let gamesLine = "Runs PSDK games released since late 2019"

    /// The Rubies in the framework: "3.0" for a game compiled on Windows,
    /// "3.2" on a Mac, "3.3" on Linux, and "2.5" for one released from
    /// December 2019 to about March 2021.
    static let rubies: Set<String> = ["2.5", "3.0", "3.2", "3.3"]

    /// A release without bytecode runs on any Ruby, so it gets the one
    /// of most games.
    static func ruby(forGameAt root: URL) -> String {
        PsdkGame.bytecodeVersion(root) ?? "3.0"
    }

    // A PSDK game reads Enter as confirm, Escape as cancel, V as the main
    // menu and B as its Y button. Its key map answers nothing for Z.
    // Measured with the probe in tools/psdk-core/prelude.rb on Edelweiss
    // Chronicles version 1 and version 48. In a 2.5 game, B is Start and
    // W is Y (the Input::Keys table in psdk/litergss1.rb).
    func defaultKeys(forGameAt root: URL) -> [GameKey] {
        let older = Self.ruby(forGameAt: root) == "2.5"
        return GameKey.standard.map {
            switch $0.scancode {
            case Int32(GAMECORE_SCANCODE_Z): GameKey(label: "V", scancode: Int32(GAMECORE_SCANCODE_V))
            case Int32(GAMECORE_SCANCODE_B) where older:
                GameKey(label: "W", scancode: Int32(GAMECORE_SCANCODE_W))
            default: $0
            }
        }
    }

    /// The core takes every PSDK folder, and refuses the ones it can't run.
    func isGameRoot(_ url: URL, fileManager: FileManager) -> Bool {
        PsdkGame.isGameRoot(url, fileManager: fileManager) || PsdkGame.isStudioProject(url)
    }

    func validateGameRoot(_ root: URL, fetch: (String) throws -> Void) throws {
        if PsdkGame.isGameRoot(root) {
            guard let version = PsdkGame.bytecodeVersion(root), !Self.rubies.contains(version) else { return }
            throw GameImportValidator.ImportError.unsupportedRuntime(
                "Empo can't run games from this version of Pokémon Studio yet."
            )
        }
        guard PsdkGame.isStudioProject(root) else { return }
        throw GameImportValidator.ImportError.unsupportedRuntime(
            "This is a Pokémon Studio project, not a game you can play yet. In Pokémon Studio, choose Compile the project, then import the game it makes."
        )
    }

    /// `isGameRoot` reads the first four bytes of Game.yarb, so both
    /// files go into the probe.
    func archiveEntryUse(_ entry: ArchiveEntry) -> ArchiveEntryUse {
        if entry.lowercaseName == "game.rb" || entry.lowercaseName == "game.yarb" { return .extract }
        if entry.isIn("graphics", "titles"), entry.isPicture { return .extract }
        return .skip
    }

    func titlePicture(at root: URL) -> URL? {
        GameCores.firstTitlesPicture(in: root)
    }

    // ponytail: reads all of Data/Scripts.dat at each launch, 0.11 s
    // for Edelweiss Chronicles on a Mac. Run it once at import and keep
    // a mark if a slow device shows the wait.
    func launch(_ container: GameContainer) {
        PsdkGame.matchFileNameCase(in: container.gameURL)
        gamecore_setSetting("rubyVersion", Self.ruby(forGameAt: container.gameURL))
    }

    /// A PSDK game ships no Game.ini, and its app_data.json holds
    /// installer state, not a title.
    var usesFolderName: Bool { true }

    @MainActor func settingsPage(_ model: GameSettingsModel) -> AnyView {
        AnyView(
            Group {
                GameplaySettingsSection(model: model)
                DisplaySettingsSection(model: model, fields: [.smoothScaling, .fixedAspectRatio])
                LayoutSettingsSection(model: model)
                Section {
                    TouchMouseToggle(model: model)
                } header: {
                    Text("Controls")
                } footer: {
                    Text("The game has to use the mouse for this to do anything.")
                }
            })
    }
}

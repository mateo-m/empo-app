import Foundation
import GameProbe
import SwiftUI

/// One PSDK core for each Ruby that Pokémon Studio compiles a release
/// with, because a Ruby can load only bytecode of its own version.
///
/// Each framework carries SFML's SFView, SFViewController and
/// SFAppDelegate, and Objective-C keeps one class for each name in a
/// process. That holds because a PSDK core can't kill its game in the
/// app (`canKillSession`), so no second PSDK core opens after it there.
/// A game process runs one core.
struct PsdkCore: GameCore {
    let ruby: String
    let gamesLine: String
    let madeWith = "PSDK"

    var framework: String { "Psdk\(ruby.replacingOccurrences(of: ".", with: ""))Core" }
    var displayName: String { "PSDK core for Ruby \(ruby)" }

    static let all = [
        PsdkCore(ruby: "2.5", gamesLine: "Runs PSDK games released from December 2019 to about March 2021"),
        PsdkCore(ruby: "3.0", gamesLine: "Runs the Windows release of PSDK games since about March 2021"),
        PsdkCore(ruby: "3.2", gamesLine: "Runs the Mac release of PSDK games"),
        PsdkCore(ruby: "3.3", gamesLine: "Runs the Linux release of PSDK games"),
    ]

    /// Takes a release without bytecode, which runs on any Ruby, and every
    /// PSDK folder that no core can run, so that the import can refuse it.
    static let fallbackRuby = "3.0"
    static let rubies = Set(all.map(\.ruby))

    static func ruby(forGameAt root: URL) -> String {
        PsdkGame.bytecodeVersion(root) ?? fallbackRuby
    }

    // A PSDK game reads Enter as confirm, Escape as cancel, V as the main
    // menu and B as its Y button. Its key map answers nothing for Z.
    // Measured with the probe in psdk-apple-mobile's
    // tools/test-host/prelude.rb on Edelweiss Chronicles version 1 and
    // version 48. In a 2.5 game, B is Start and W is Y (the Input::Keys
    // table in the core's support/litergss1.rb).
    func defaultKeys(forGameAt root: URL) -> [GameKey] {
        let older = ruby == "2.5"
        return GameKey.standard.map {
            switch $0.scancode {
            case Int32(GAMECORE_SCANCODE_Z): GameKey(label: "V", scancode: Int32(GAMECORE_SCANCODE_V))
            case Int32(GAMECORE_SCANCODE_B) where older:
                GameKey(label: "W", scancode: Int32(GAMECORE_SCANCODE_W))
            default: $0
            }
        }
    }

    func isGameRoot(_ url: URL, fileManager: FileManager) -> Bool {
        guard PsdkGame.isGameRoot(url, fileManager: fileManager) || PsdkGame.isStudioProject(url) else {
            return false
        }
        let version = Self.ruby(forGameAt: url)
        return version == ruby || (ruby == Self.fallbackRuby && !Self.rubies.contains(version))
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
        let settings = GameSettings.load(from: container.empoStateURL)
        let smooth = settings.smoothScaling ?? GameConfigDefaults.engineSmoothScaling
        let fixed = settings.fixedAspectRatio ?? GameConfigDefaults.engineFixedAspectRatio
        gamecore_setSetting("smoothScaling", smooth ? "1" : "0")
        gamecore_setSetting("fixedAspectRatio", fixed ? "1" : "0")
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

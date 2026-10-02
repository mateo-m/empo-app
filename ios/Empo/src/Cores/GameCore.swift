import Foundation
import SwiftUI

/// The app side of one game core. Each core answers for its own games:
/// which folders it runs, how an import checks them, which settings they
/// have, and which keys they read. The rest of the app asks
/// `GameCores.core(forGameAt:)` and never names a core.
///
/// A requirement without a default in the extension below is one that
/// every core must answer.
protocol GameCore {
    /// The framework folder in the app bundle, and the binary inside it.
    var framework: String { get }
    var displayName: String { get }
    /// The line under the name on the Game cores screen.
    var gamesLine: String { get }
    /// The tool the games were made with. The Game cores screen groups
    /// the cores by it.
    var madeWith: String { get }
    /// The games of this core, as a setting names them.
    var gamesName: String { get }
    var supportsCheats: Bool { get }
    var scriptLanguage: GameScriptLanguage { get }
    /// True when `gamecore_killSession` kills the running game and frees
    /// all of its state. Then any number of games, on any core, can run
    /// after it in the app, with nothing left from this one.
    var canKillSession: Bool { get }
    /// The four keys of the builtin button grid, in grid order.
    func defaultKeys(forGameAt root: URL) -> [GameKey]

    func isGameRoot(_ url: URL, fileManager: FileManager) -> Bool

    /// What an archive probe does with one entry of the archive.
    func archiveEntryUse(_ entry: ArchiveEntry) -> ArchiveEntryUse
    /// Checks a folder that holds an entry this core marked, before the
    /// folder is on disk. `marker` is the lowercase name of that entry.
    func validateMarkedRoot(marker: String) throws
    /// Checks a folder that `isGameRoot` accepts. `fetch` makes sure that
    /// a file, given relative to `root`, is on disk. During an archive
    /// probe it extracts the file.
    func validateGameRoot(_ root: URL, fetch: (String) throws -> Void) throws

    /// The title the game gives itself.
    func title(at root: URL) -> String?
    func titlePicture(at root: URL) -> URL?
    /// True when a game of this core has no title of its own, so the
    /// library shows the name of its folder.
    var usesFolderName: Bool { get }

    func didImport(_ container: GameContainer, from source: ImportSource, replacing: Bool)
    /// The JoiPlay archive types (the `type` of `manifest.json`) this
    /// core runs.
    var joiPlayTypes: Set<String> { get }
    /// The games of `joiPlayTypes`, as the import error names them.
    var joiPlayGames: String? { get }

    /// Makes the game ready to run and sends the per-game settings of
    /// this core with `gamecore_setSetting`. The app calls it before
    /// `gamecore_applySessionConfig`.
    func launch(_ container: GameContainer)
    func launchWarning(for container: GameContainer, gameTitle: String) -> LaunchWarning?

    @MainActor func makeSettings(for container: GameContainer) -> (any CoreSettings)?
    func displayDefaults(for container: GameContainer) -> GameDisplayDefaults
    /// The folder under `Documents/Data/` that the app gives the game for
    /// its saves, as path components. Two games with the same folder
    /// share their saves. Nil when the game keeps its files in its own
    /// folder.
    func sharedDataFolder(for container: GameContainer) -> [String]?
    @MainActor func settingsPage(_ model: GameSettingsModel) -> AnyView

    /// Rows for the Runtime section of Game Info. Empty hides the section.
    func infoRows(for container: GameContainer) async -> [InfoRow]
}

extension GameCore {
    var supportsCheats: Bool { false }
    var gamesName: String { madeWith }
    var canKillSession: Bool { false }
    func defaultKeys(forGameAt root: URL) -> [GameKey] { GameKey.standard }
    func archiveEntryUse(_ entry: ArchiveEntry) -> ArchiveEntryUse { .skip }
    func validateMarkedRoot(marker: String) throws {}
    func validateGameRoot(_ root: URL, fetch: (String) throws -> Void) throws {}
    func title(at root: URL) -> String? { nil }
    func titlePicture(at root: URL) -> URL? { nil }
    var usesFolderName: Bool { false }

    /// The title the library shows until the user sets one.
    func defaultTitle(of container: GameContainer) -> String? {
        title(at: container.gameURL) ?? (usesFolderName ? container.folderName : nil)
    }

    func didImport(_ container: GameContainer, from source: ImportSource, replacing: Bool) {}
    var joiPlayTypes: Set<String> { [] }
    var joiPlayGames: String? { nil }
    func launch(_ container: GameContainer) {}
    func launchWarning(for container: GameContainer, gameTitle: String) -> LaunchWarning? { nil }
    @MainActor func makeSettings(for container: GameContainer) -> (any CoreSettings)? { nil }
    func displayDefaults(for container: GameContainer) -> GameDisplayDefaults { GameDisplayDefaults() }
    func sharedDataFolder(for container: GameContainer) -> [String]? { nil }
    func infoRows(for container: GameContainer) async -> [InfoRow] { [] }

    var notInThisBuildMessage: String {
        "This build of Empo has no \(displayName), so it can't run this game."
    }

    /// `EngineSessionCoordinator.openCore` opens this path, so a core is
    /// part of the build only when the binary is there. An embed phase
    /// that skips a core leaves no framework folder at all.
    var binaryURL: URL? {
        guard
            let url = Bundle.main.privateFrameworksURL?
                .appendingPathComponent("\(framework).framework")
                .appendingPathComponent(framework),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    var isInThisBuild: Bool { binaryURL != nil }

    var bundle: Bundle? {
        binaryURL.flatMap { Bundle(url: $0.deletingLastPathComponent()) }
    }

    /// The build-framework-ios.sh scripts write EmpoCoreVersion.
    var version: String {
        bundle?.object(forInfoDictionaryKey: "EmpoCoreVersion") as? String ?? "unknown"
    }
}

/// The language the scripts of a core's games are in.
enum GameScriptLanguage: String {
    case ruby
    case javaScript
}

enum GameCores {
    /// The first core that accepts a folder runs it.
    static let all: [any GameCore] = PsdkCore.all + [MvmzCore(), MkxpCore()]

    static var inThisBuild: [any GameCore] { all.filter(\.isInThisBuild) }

    static var rubyInThisBuild: [any GameCore] { inThisBuild.filter { $0.scriptLanguage == .ruby } }

    /// The games of the Ruby cores in this build, for example "PSDK
    /// games and RPG Maker XP, VX and VX Ace games".
    static var rubyGamesName: String {
        var names: [String] = []
        for core in rubyInThisBuild where !names.contains("\(core.gamesName) games") {
            names.append("\(core.gamesName) games")
        }
        return ListFormatter.localizedString(byJoining: names)
    }

    static func core(forGameAt url: URL, fileManager: FileManager = .default) -> (any GameCore)? {
        all.first { $0.isGameRoot(url, fileManager: fileManager) }
    }

    /// The first picture in `Graphics/Titles`, where RGSS and PSDK games
    /// keep their title screens.
    static func firstTitlesPicture(in root: URL) -> URL? {
        let titles = root.appendingPathComponent("Graphics/Titles")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: titles.path) else {
            return nil
        }
        return items.sorted()
            .first { ArchiveEntry.pictureExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { titles.appendingPathComponent($0) }
    }
}

struct GameKey: Equatable {
    let label: String
    let scancode: Int32

    static let standard = [
        GameKey(label: "Enter", scancode: Int32(GAMECORE_SCANCODE_RETURN)),
        GameKey(label: "Escape", scancode: Int32(GAMECORE_SCANCODE_ESCAPE)),
        GameKey(label: "Z", scancode: Int32(GAMECORE_SCANCODE_Z)),
        GameKey(label: "B", scancode: Int32(GAMECORE_SCANCODE_B)),
    ]
}

/// One file of an archive, before the probe extracts anything.
struct ArchiveEntry {
    let lowercaseName: String
    let parentComponents: [String]
    let parentPath: String

    static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp"]

    init?(_ rawPath: String) {
        let components =
            rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let name = components.last, !name.isEmpty else { return nil }
        lowercaseName = name.lowercased()
        parentComponents = Array(components.dropLast())
        parentPath = parentComponents.joined(separator: "/")
    }

    /// True when the parent folders end with `folders`, compared without case.
    func isIn(_ folders: String...) -> Bool {
        guard parentComponents.count >= folders.count else { return false }
        return zip(parentComponents.suffix(folders.count), folders)
            .allSatisfy { $0.lowercased() == $1 }
    }

    var isPicture: Bool {
        Self.pictureExtensions.contains((lowercaseName as NSString).pathExtension)
    }
}

enum ArchiveEntryUse {
    case skip
    case extract
    /// The entry is too large to extract for a probe, and its folder is a
    /// game root of this core.
    case markRoot
}

enum ImportSource {
    case folder
    case archive
    case joiPlay(type: String)
}

struct LaunchWarning {
    let title: String
    let message: String
    let confirm: String
}

struct InfoRow: Identifiable {
    let label: String
    /// Nil shows "Unknown".
    let value: String?

    var id: String { label }
}

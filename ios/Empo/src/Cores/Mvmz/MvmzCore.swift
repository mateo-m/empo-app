import Foundation
import GameProbe
import SwiftUI

struct MvmzCore: GameCore {
    let framework = "MvmzCore"
    let displayName = "RPG Maker MV and MZ core"
    let gamesLine = "Runs RPG Maker MV and MZ games"
    let madeWith = "RPG Maker"

    /// WebKit ends the page and all of its JavaScript when the core
    /// removes its web view.
    var canKillSession: Bool { true }

    // MV and MZ read B as nothing, and Shift as dash (Input.keyMapper in
    // rpg_core.js and rmmz_core.js).
    func defaultKeys(forGameAt root: URL) -> [GameKey] {
        GameKey.standard.map {
            $0.scancode == Int32(GAMECORE_SCANCODE_B)
                ? GameKey(label: "Shift", scancode: Int32(GAMECORE_SCANCODE_LSHIFT)) : $0
        }
    }

    func isGameRoot(_ url: URL, fileManager: FileManager) -> Bool {
        MvmzGame.isGameRoot(url, fileManager: fileManager)
    }

    /// System.json also holds the title.
    func archiveEntryUse(_ entry: ArchiveEntry) -> ArchiveEntryUse {
        if entry.lowercaseName == "index.html" { return .extract }
        if entry.lowercaseName == "system.json", entry.isIn("data") { return .extract }
        return .skip
    }

    func title(at root: URL) -> String? {
        MvmzGame.title(at: root)
    }

    func titlePicture(at root: URL) -> URL? {
        MvmzGame.titlePicture(at: root)
    }

    /// The game reads touches itself, so it needs no "Touch acts as
    /// mouse" row, and it keeps its own proportions in the web view.
    @MainActor func settingsPage(_ model: GameSettingsModel) -> AnyView {
        AnyView(
            Group {
                GameplaySettingsSection(model: model)
                DisplaySettingsSection(model: model, fields: [.smoothScaling])
                LayoutSettingsSection(model: model)
            })
    }
}

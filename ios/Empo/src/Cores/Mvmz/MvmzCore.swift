// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe
import SwiftUI

struct MvmzCore: GameCore {
    let framework = "MvmzCore"
    var displayName: String { String(localized: "RPG Maker MV and MZ core") }
    var gamesLine: String { String(localized: "Runs RPG Maker MV and MZ games") }
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

    /// NW.js runs a desktop MV release from the folder of its top
    /// `package.json`, and a game can read files such as `lng.txt` from
    /// there. The core runs the `www` folder, so those files go into it.
    func prepareImport(of root: URL) throws {
        let fm = FileManager.default
        let release = root.deletingLastPathComponent()
        guard
            let data = try? Data(contentsOf: release.appendingPathComponent("package.json")),
            let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let main = package["main"] as? String,
            release.appendingPathComponent(main).standardizedFileURL.path
                == root.appendingPathComponent("index.html").standardizedFileURL.path
        else { return }
        GameContainer.normalizeImportedGamePermissions(at: root)
        let runtimeExtensions: Set<String> = ["exe", "dll", "pak", "bin", "dat"]
        let files = try fm.contentsOfDirectory(
            at: release, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)
        for file in files where !runtimeExtensions.contains(file.pathExtension.lowercased()) {
            let copy = root.appendingPathComponent(file.lastPathComponent)
            guard
                try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                !fm.fileExists(atPath: copy.path)
            else { continue }
            try fm.copyItem(at: file, to: copy)
        }
    }

    func title(at root: URL) -> String? {
        MvmzGame.title(at: root)
    }

    func titlePicture(at root: URL) -> URL? {
        MvmzGame.titlePicture(at: root)
    }

    func madeWith(at root: URL) -> String {
        MvmzGame.isMZ(at: root) ? "RPG Maker MZ" : "RPG Maker MV"
    }

    func launch(_ container: GameContainer) -> [CoreSetting] {
        [smoothScaling(GameSettings.load(from: container.empoStateURL))]
    }

    /// The game reads touches itself, so it needs no "Touch acts as
    /// mouse" row, and it keeps its own proportions in the web view.
    @MainActor func settingsPage(_ model: GameSettingsModel) -> AnyView {
        AnyView(
            Group {
                GameplaySettingsSection(model: model)
                DisplaySettingsSection(model: model, fields: [.smoothScaling])
                #if os(iOS)
                LayoutSettingsSection(model: model)
                #endif
            })
    }
}

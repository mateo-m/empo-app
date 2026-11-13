// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

@MainActor
final class RestartHintTests: XCTestCase {
    private var container: GameContainer!

    override func setUp() async throws {
        container = GameContainer(folderName: "restart-hint-\(UUID().uuidString)")
        try container.ensureSubdirs()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: container.url)
        guard let appSoundSetBackup else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: MidiSoundSet.app.folderURL)
        if fm.fileExists(atPath: appSoundSetBackup.path) {
            try fm.moveItem(at: appSoundSetBackup, to: MidiSoundSet.app.folderURL)
        }
    }

    private var appSoundSetBackup: URL?

    func testHintStaysWhenTheSettingsOpenAgain() throws {
        let game = GameEntry(id: "game", container: container, title: "Game", artworkPath: nil)
        let launched = LaunchedSettings(settings: GameSettings.load(from: container.empoStateURL), core: nil)

        let first = GameSettingsModel(game: game, container: container)
        XCTAssertNil(first.restartHint(since: launched))
        first.settings.smoothScaling = true
        first.save()

        let reopened = try XCTUnwrap(
            GameSettingsModel(game: game, container: container).restartHint(since: launched))
        XCTAssertEqual(String(localized: reopened), "Restart this game to apply: Smooth scaling.")
    }

    func testClosingTheSettingsAfterARestoreKeepsTheRestoredSettings() {
        let game = GameEntry(id: "game", container: container, title: "Game", artworkPath: nil)
        let model = GameSettingsModel(game: game, container: container)
        model.settings.smoothScaling = true
        model.save()

        var restored = GameSettings()
        restored.smoothScaling = false
        restored.save(to: container.empoStateURL)
        model.reload()
        model.save()

        XCTAssertEqual(GameSettings.load(from: container.empoStateURL).smoothScaling, false)
    }

    func testCoreSettingsCompareWithTheSettingsAtLaunch() {
        let launched = MkxpLaunchedSettings(container: container)
        let edited = MkxpSettingsState(container: container)
        XCTAssertEqual(launched.restartRequiredChanges(to: edited), [])

        edited.settings.postloadScripts = true
        edited.save()

        XCTAssertEqual(
            launched.restartRequiredChanges(to: MkxpSettingsState(container: container)), ["Fix-up scripts"])
    }

    func testSameNameImportNeedsARestart() throws {
        choose(.imported)
        try writeSoundSet(into: MidiSoundSet.game(container).folderURL)
        let launched = MkxpLaunchedSettings(container: container)
        XCTAssertEqual(launched.restartRequiredChanges(to: MkxpSettingsState(container: container)), [])

        try MidiSoundSet.game(container).removeImported()
        try writeSoundSet(into: MidiSoundSet.game(container).folderURL)

        XCTAssertEqual(
            launched.restartRequiredChanges(to: MkxpSettingsState(container: container)), ["MIDI sound set"])
    }

    func testAppSoundSetChangeNeedsARestartOnlyForDefault() throws {
        try moveAppSoundSetAside()
        let followsDefault = MkxpLaunchedSettings(container: container)
        choose(.builtIn)
        let builtIn = MkxpLaunchedSettings(container: container)

        try writeSoundSet(into: MidiSoundSet.app.folderURL)

        XCTAssertEqual(builtIn.restartRequiredChanges(to: MkxpSettingsState(container: container)), [])
        choose(nil)
        XCTAssertEqual(
            followsDefault.restartRequiredChanges(to: MkxpSettingsState(container: container)),
            ["MIDI sound set"])
    }

    func testAppSoundSetChangeNeedsNoRestartWhenTheGameShipsOne() throws {
        try moveAppSoundSetAside()
        try writeSoundSet(into: container.gameURL.appendingPathComponent("Audio", isDirectory: true))
        let launched = MkxpLaunchedSettings(container: container)

        try writeSoundSet(into: MidiSoundSet.app.folderURL)

        XCTAssertEqual(launched.restartRequiredChanges(to: MkxpSettingsState(container: container)), [])
    }

    func testSoundFontAddedToTheGameFolderNeedsARestart() throws {
        try moveAppSoundSetAside()
        let launched = MkxpLaunchedSettings(container: container)

        try writeSoundSet(into: container.gameURL.appendingPathComponent("Audio", isDirectory: true))

        XCTAssertEqual(
            launched.restartRequiredChanges(to: MkxpSettingsState(container: container)), ["MIDI sound set"])
    }

    private func choose(_ soundSet: GameMidiSoundSet?) {
        var settings = MkxpSettings.load(from: container.empoStateURL)
        settings.midiSoundSet = soundSet
        settings.save(to: container.empoStateURL)
    }

    /// The restart hint compares paths and file numbers, so the bytes do not matter.
    private func writeSoundSet(into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: folder.appendingPathComponent("Set.sf2"))
    }

    private func moveAppSoundSetAside() throws {
        let fm = FileManager.default
        let backup = fm.temporaryDirectory.appendingPathComponent("SoundFonts-\(UUID().uuidString)")
        appSoundSetBackup = backup
        if fm.fileExists(atPath: MidiSoundSet.app.folderURL.path) {
            try fm.moveItem(at: MidiSoundSet.app.folderURL, to: backup)
        }
    }
}

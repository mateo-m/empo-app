import Foundation
import XCTest

@testable import GameProbe

/// The classifier signals SPEC 3.6 adds to `PortableGameSaves`:
/// `.sav` and the common custom save names.
///
/// The signals form a union, and a false positive only backs up one
/// more file. A false negative loses a save, so the rules lean in.
final class ClassifierSignalsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassifierSignals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func write(_ name: String, bytes: [UInt8] = [0x41, 0x42]) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    private var names: [String] {
        PortableGameSaves.entryNames(atGameRoot: root)
    }

    // MARK: - One fixture per new signal

    func testTheSavExtensionIsASave() throws {
        try write("autosave.sav")

        XCTAssertEqual(names, ["autosave.sav"])
    }

    func testTheSaveExtensionIsASave() throws {
        try write("slot3.save")

        XCTAssertEqual(names, ["slot3.save"])
    }

    func testTheSavedataExtensionIsASave() throws {
        try write("player.savedata")

        XCTAssertEqual(names, ["player.savedata"])
    }

    func testASaveShapedStemIsASaveWhateverTheExtension() throws {
        try write("save.dat")
        try write("savefile.bin")
        try write("game_save.json")

        XCTAssertEqual(names, ["game_save.json", "save.dat", "savefile.bin"])
    }

    func testASlotNumberOnTheStemStillMatches() throws {
        try write("save1.dat")
        try write("save_2.dat")
        try write("save-3.dat")

        XCTAssertEqual(names, ["save-3.dat", "save1.dat", "save_2.dat"])
    }

    func testAStemWithNoExtensionMatches() throws {
        try write("savedata")

        XCTAssertEqual(names, ["savedata"])
    }

    func testABakWrapperOnANewSignalStillMatches() throws {
        try write("autosave.sav.bak")

        XCTAssertEqual(names, ["autosave.sav.bak"])
    }

    func testTheNewSaveFolderNamesAreTakenWhole() throws {
        try write("SaveGames/one.bin")
        try write("Saved Games/two.bin")

        XCTAssertEqual(names, ["SaveGames", "Saved Games"])
    }

    // MARK: - What the new signals must not take

    func testAnOrdinaryGameFileIsNoSave() throws {
        try write("Game.ini")
        try write("Game.exe")
        try write("readme.txt")

        XCTAssertTrue(names.isEmpty, "the classifier took \(names)")
    }

    func testASavelikeWordInsideALongerNameIsNoSave() throws {
        try write("savings-report.txt")
        try write("unsaved.txt")

        XCTAssertTrue(names.isEmpty, "the classifier took \(names)")
    }

    func testAHiddenFileIsNoSave() throws {
        try write(".save")

        XCTAssertTrue(names.isEmpty, "the classifier took \(names)")
    }

    func testAnEngineDirectoryIsStillNeverEntered() throws {
        try write("Data/save.dat")
        try write("Graphics/save.png")

        XCTAssertTrue(names.isEmpty, "the classifier took \(names)")
    }

    // MARK: - The old signals still hold

    func testTheRGSSExtensionsStillMatch() throws {
        try write("Game.rxdata")
        try write("Game.rvdata2.bak")

        XCTAssertEqual(names, ["Game.rvdata2.bak", "Game.rxdata"])
    }

    func testTheMarshalMagicStillMatches() throws {
        try write("Uranium_1", bytes: [0x04, 0x08, 0x7B])

        XCTAssertEqual(names, ["Uranium_1"])
    }
}

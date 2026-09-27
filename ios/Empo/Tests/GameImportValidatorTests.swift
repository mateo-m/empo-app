import XCTest

@testable import Empo

final class GameImportValidatorTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameImportValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testALoneWrappedRootTakesTheNameOfThePickedFolder() throws {
        // The Windows release of Edelweiss Chronicles nests the game in
        // `app/`, next to `patcher/`.
        let picked = scratch.appendingPathComponent("Edelweiss Chronicles 1.4", isDirectory: true)
        try makePsdkGame(at: picked.appendingPathComponent("app", isDirectory: true))
        try FileManager.default.createDirectory(
            at: picked.appendingPathComponent("patcher", isDirectory: true),
            withIntermediateDirectories: true
        )

        let choices = try GameImportValidator.importRootChoices(for: picked).choices

        XCTAssertEqual(choices.map(\.title), ["Edelweiss Chronicles 1.4"])
        XCTAssertEqual(choices.map(\.relativePath), ["app"])
    }

    func testTwoRootsKeepTheirFolderNames() throws {
        let picked = scratch.appendingPathComponent("Two Games", isDirectory: true)
        try makePsdkGame(at: picked.appendingPathComponent("first", isDirectory: true))
        try makePsdkGame(at: picked.appendingPathComponent("second", isDirectory: true))

        let titles = try GameImportValidator.importRootChoices(for: picked).choices.map(\.title)

        XCTAssertEqual(titles.sorted(), ["first", "second"])
    }

    func testThePickedGameFolderKeepsItsOwnName() throws {
        let picked = scratch.appendingPathComponent("Edelweiss Chronicles", isDirectory: true)
        try makePsdkGame(at: picked)

        let choices = try GameImportValidator.importRootChoices(for: picked).choices

        XCTAssertEqual(choices.map(\.title), ["Edelweiss Chronicles"])
        XCTAssertEqual(choices.map(\.relativePath), [""])
    }

    /// An RPG Maker game keeps the name it had before Empo learned to
    /// name a lone root after the source. The name becomes the container
    /// folder, and the importer matches an installed game by that folder
    /// (`ImportNameResolution.resolve`). A name that moves between two
    /// Empo versions installs the same game twice.
    func testAnRPGMakerGameKeepsItsFolderName() throws {
        let picked = scratch.appendingPathComponent("Alpha Quest 1.2", isDirectory: true)
        try makeRPGMakerGame(at: picked.appendingPathComponent("Game", isDirectory: true))

        let choices = try GameImportValidator.importRootChoices(for: picked).choices

        XCTAssertEqual(choices.map(\.title), ["Game"])
        XCTAssertEqual(choices.map(\.relativePath), ["Game"])
    }

    func testAnRPGMakerGameStillPrefersItsDeclaredTitle() throws {
        let picked = scratch.appendingPathComponent("Alpha Quest 1.2", isDirectory: true)
        let root = picked.appendingPathComponent("Game", isDirectory: true)
        try makeRPGMakerGame(at: root)
        try Data("[Game]\nTitle=Alpha Quest\n".utf8)
            .write(to: root.appendingPathComponent("Game.ini"))

        let choices = try GameImportValidator.importRootChoices(for: picked).choices

        XCTAssertEqual(choices.map(\.title), ["Alpha Quest"])
    }

    func testADesktopMVReleaseImportsItsWwwFolderWithTheGameTitle() throws {
        let picked = scratch.appendingPathComponent("Sorcery of Truth 1.0", isDirectory: true)
        let www = picked.appendingPathComponent("www", isDirectory: true)
        try FileManager.default.createDirectory(
            at: www.appendingPathComponent("data", isDirectory: true), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: picked.appendingPathComponent("Game.exe"))
        try Data("<html>".utf8).write(to: www.appendingPathComponent("index.html"))
        try Data(#"{"gameTitle":"Sorcery of Truth"}"#.utf8)
            .write(to: www.appendingPathComponent("data/System.json"))

        let choices = try GameImportValidator.importRootChoices(for: picked).choices

        XCTAssertEqual(choices.map(\.title), ["Sorcery of Truth"])
        XCTAssertEqual(choices.map(\.relativePath), ["www"])
        XCTAssertNoThrow(try GameImportValidator.validate(picked))
    }

    /// An RGSS archive is proof enough for `validate`, and RGSS1 runs on
    /// every core build, so the mask check passes either way.
    private func makeRPGMakerGame(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("RGSSAD".utf8).write(to: url.appendingPathComponent("Game.rgssad"))
    }

    /// The PSDK core takes a Game.rb next to a Game.yarb that Ruby 3.0
    /// compiled: YARB, then major version 3 and minor version 0.
    private func makePsdkGame(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("RubyVM\n".utf8).write(to: url.appendingPathComponent("Game.rb"))
        try (Data("YARB".utf8) + Data([3, 0, 0, 0, 0, 0, 0, 0]))
            .write(to: url.appendingPathComponent("Game.yarb"))
    }
}

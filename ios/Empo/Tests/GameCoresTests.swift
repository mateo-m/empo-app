import XCTest

@testable import Empo

final class GameCoresTests: XCTestCase {
    /// The screen names a core when the app can open it, and stays
    /// silent when it cannot.
    func testTheScreenNamesEveryCoreTheAppCanOpen() throws {
        let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)

        for core in GameCores.all {
            let binary =
                frameworks
                .appendingPathComponent("\(core.framework).framework")
                .appendingPathComponent(core.framework)
            let inBundle = FileManager.default.fileExists(atPath: binary.path)
            XCTAssertEqual(
                core.isInThisBuild, inBundle,
                "\(core.framework): the screen says \(core.isInThisBuild), the bundle says \(inBundle)")
        }
    }

    func testEveryCoreOnTheScreenCarriesAVersion() {
        XCTAssertFalse(GameCores.inThisBuild.isEmpty, "this build runs no game")
        for core in GameCores.inThisBuild {
            XCTAssertNotEqual(
                core.version, "unknown",
                "\(core.framework).framework has no EmpoCoreVersion in its Info.plist")
        }
    }

    func testEveryCoreHasItsOwnFramework() {
        XCTAssertEqual(Set(GameCores.all.map(\.framework)).count, GameCores.all.count)
    }

    /// A zero mask makes the import skip the RGSS check, which is right
    /// only when the core is absent.
    func testTheRGSSMaskFollowsTheRPGMakerCore() {
        let core = MkxpCore()
        if core.isInThisBuild {
            XCTAssertTrue(
                core.rgssVersionMask == 3 || core.rgssVersionMask == 7,
                "unexpected RGSS mask \(core.rgssVersionMask)")
        } else {
            XCTAssertEqual(core.rgssVersionMask, 0)
        }
    }

    func testAPsdkFolderAsksForTheCoreOfItsRuby() throws {
        let psdk = try makeDirectory("psdk")
        try Data("RubyVM\n".utf8).write(to: psdk.appendingPathComponent("Game.rb"))

        // The version in each Game.yarb header picks the core: 3.2 is a
        // game compiled on a Mac, 3.3 on Linux, 2.5 a release of 2020.
        for (major, minor, framework) in [
            (3, 2, "Psdk32Core"), (3, 3, "Psdk33Core"), (2, 5, "Psdk25Core"), (3, 0, "Psdk30Core"),
        ] as [(UInt8, UInt8, String)] {
            try Data("YARB".utf8 + [major, 0, 0, 0, minor, 0, 0, 0]).write(
                to: psdk.appendingPathComponent("Game.yarb"))
            let core = try XCTUnwrap(GameCores.core(forGameAt: psdk), framework)
            XCTAssertEqual(core.framework, framework)
            XCTAssertNoThrow(try core.validateGameRoot(psdk) { _ in }, framework)
            // In a 2.5 game, W is the Y button.
            XCTAssertEqual(
                core.defaultKeys(forGameAt: psdk).map(\.label),
                ["Enter", "Escape", "V", major == 2 ? "W" : "B"], framework)
        }

        // No core loads bytecode of Ruby 3.1, so the 3.0 core takes the
        // game and the import refuses it.
        try Data("YARB".utf8 + [3, 0, 0, 0, 1, 0, 0, 0]).write(to: psdk.appendingPathComponent("Game.yarb"))
        let refused = try XCTUnwrap(GameCores.core(forGameAt: psdk))
        XCTAssertEqual(refused.framework, "Psdk30Core")
        XCTAssertThrowsError(try refused.validateGameRoot(psdk) { _ in })

        // A release compiled with --no-yarb runs on any Ruby.
        try FileManager.default.removeItem(at: psdk.appendingPathComponent("Game.yarb"))
        try Data("PSDK_VERSION = 6716\nFile.binread('Data/Scripts.dat')\n".utf8)
            .write(to: psdk.appendingPathComponent("Game.rb"))
        let anyRuby = try XCTUnwrap(GameCores.core(forGameAt: psdk))
        XCTAssertEqual(anyRuby.framework, "Psdk30Core")
        XCTAssertNoThrow(try anyRuby.validateGameRoot(psdk) { _ in })

        let other = psdk.appendingPathComponent("Graphics", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertNil(GameCores.core(forGameAt: other))
    }

    func testAnMvOrMzFolderAsksForTheMvmzCore() throws {
        let game = try makeDirectory("mvmz")
        let data = game.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("<html>".utf8).write(to: game.appendingPathComponent("index.html"))
        try Data("{}".utf8).write(to: data.appendingPathComponent("System.json"))

        XCTAssertEqual(GameCores.core(forGameAt: game)?.framework, "MvmzCore")
        XCTAssertNil(GameCores.core(forGameAt: data))
    }

    func testAnRGSSFolderAsksForTheRPGMakerCore() throws {
        let game = try makeDirectory("rgss")
        try Data().write(to: game.appendingPathComponent("Game.rgss3a"))

        XCTAssertEqual(GameCores.core(forGameAt: game)?.framework, "MkxpCore")
    }

    /// An RGSS archive holds the whole game, so the probe marks its folder
    /// and does not extract it.
    func testTheProbeMarksAnRGSSArchiveAndExtractsTheMarkers() throws {
        let use = { (path: String) in
            GameCores.all.map { $0.archiveEntryUse(try! XCTUnwrap(ArchiveEntry(path))) }
        }
        XCTAssertTrue(use("Game/Game.rgssad").contains(.markRoot))
        XCTAssertTrue(use("Game/Game.ini").contains(.extract))
        XCTAssertTrue(use("Game/Data/Scripts.rvdata2").contains(.extract))
        XCTAssertTrue(use("Game/Game.yarb").contains(.extract))
        XCTAssertTrue(use("Game/data/System.json").contains(.extract))
        XCTAssertTrue(use("Game/Graphics/Titles/Title.png").contains(.extract))
        XCTAssertEqual(Set(use("Game/Audio/BGM/Theme.ogg")), [.skip])
    }

    func testTheRefusalNamesTheMissingCore() {
        for core in PsdkCore.all {
            XCTAssertTrue(
                core.notInThisBuildMessage.contains("PSDK core for Ruby \(core.ruby)"),
                core.notInThisBuildMessage)
        }
        XCTAssertTrue(
            MkxpCore().notInThisBuildMessage.contains("RPG Maker XP"),
            MkxpCore().notInThisBuildMessage)
    }

    /// The import error lists what every core accepts, so the words
    /// stay the same as before the cores listed them.
    func testTheJoiPlayRefusalListsTheAcceptedGames() {
        let games = GameCores.all.compactMap(\.joiPlayGames).joined(separator: " and ")
        XCTAssertEqual(games, "RPG Maker XP, VX, VX Ace, and mkxp-z games")
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

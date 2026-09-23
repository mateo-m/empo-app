import XCTest

@testable import Empo

final class BuiltInGameCoreTests: XCTestCase {
    /// The screen names a core when the app can open it, and stays
    /// silent when it cannot.
    func testTheScreenNamesEveryCoreTheAppCanOpen() throws {
        let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)

        for kind in GameCoreKind.allCases {
            let binary =
                frameworks
                .appendingPathComponent("\(kind.rawValue).framework")
                .appendingPathComponent(kind.rawValue)
            let inBundle = FileManager.default.fileExists(atPath: binary.path)
            let onScreen = BuiltInGameCore.isInThisBuild(kind)
            XCTAssertEqual(
                onScreen, inBundle,
                "\(kind.rawValue): the screen says \(onScreen), the bundle says \(inBundle)")
        }
    }

    func testEveryCoreOnTheScreenCarriesAVersion() {
        XCTAssertFalse(BuiltInGameCore.all.isEmpty, "this build runs no game")
        for core in BuiltInGameCore.all {
            XCTAssertNotEqual(
                core.version, "unknown",
                "\(core.id).framework has no EmpoCoreVersion in its Info.plist")
        }
    }

    /// A zero mask makes GameImportValidator refuse every RPG Maker
    /// game, which is right only when the core is absent.
    func testTheRGSSMaskFollowsTheRPGMakerCore() {
        let mask = BuiltInGameCore.rgssVersionMask
        if BuiltInGameCore.isInThisBuild(.rpgMaker) {
            XCTAssertTrue(mask == 3 || mask == 7, "unexpected RGSS mask \(mask)")
        } else {
            XCTAssertEqual(mask, 0)
        }
    }

    func testAPsdkFolderAsksForThePsdkCore() throws {
        let psdk = FileManager.default.temporaryDirectory
            .appendingPathComponent("psdk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: psdk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: psdk) }
        try Data("RubyVM\n".utf8).write(to: psdk.appendingPathComponent("Game.rb"))
        try Data("YARB".utf8).write(to: psdk.appendingPathComponent("Game.yarb"))

        XCTAssertEqual(GameCoreKind.forGame(at: psdk), .psdk)

        let other = psdk.appendingPathComponent("Graphics", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(GameCoreKind.forGame(at: other), .rpgMaker)
    }

    func testTheRefusalNamesTheMissingCore() {
        XCTAssertTrue(
            GameCoreKind.psdk.notInThisBuildMessage.contains("PSDK core"),
            GameCoreKind.psdk.notInThisBuildMessage)
        XCTAssertTrue(
            GameCoreKind.rpgMaker.notInThisBuildMessage.contains("RPG Maker core"),
            GameCoreKind.rpgMaker.notInThisBuildMessage)
    }
}

import Foundation
import XCTest

@testable import GameProbe

final class MvmzGameTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mvmz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }

    func testAGameFolderIsAGameRootWithItsTitle() throws {
        try write("index.html", "<html>")
        try write("data/System.json", #"{"gameTitle":" Stella's First RPG ","locale":"en_US"}"#)
        XCTAssertTrue(MvmzGame.isGameRoot(root))
        XCTAssertEqual(MvmzGame.title(at: root), "Stella's First RPG")
    }

    func testTheTitlePictureIsTheOneSystemJsonNames() throws {
        try write("data/System.json", #"{"title1Name":"Castle"}"#)
        XCTAssertNil(MvmzGame.titlePicture(at: root))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("img/titles1"), withIntermediateDirectories: true)
        try write("img/titles1/Book.png", "")
        try write("img/titles1/Castle.png", "")
        XCTAssertEqual(MvmzGame.titlePicture(at: root)?.lastPathComponent, "Castle.png")
    }

    func testAnEmptyTitleIsNoTitle() throws {
        try write("data/System.json", #"{"gameTitle":""}"#)
        XCTAssertNil(MvmzGame.title(at: root))
    }

    func testAnRPGMakerXPFolderIsNotAnMvmzGame() throws {
        try write("Game.ini", "[Game]")
        XCTAssertFalse(MvmzGame.isGameRoot(root))
    }
}

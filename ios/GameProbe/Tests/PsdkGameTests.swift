import Foundation
import XCTest

@testable import GameProbe

final class PsdkGameTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("psdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: root.appendingPathComponent(name))
    }

    /// The first 16 bytes of Edelweiss Chronicles' Game.yarb.
    private let yarb: [UInt8] = [
        0x59, 0x41, 0x52, 0x42, 0x03, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xb0, 0x62, 0x00, 0x00,
    ]

    func testAReleasedGameIsAGameRoot() throws {
        try write("Game.rb", Array("RubyVM::InstructionSequence".utf8))
        try write("Game.yarb", yarb)
        XCTAssertTrue(PsdkGame.isGameRoot(root))
    }

    func testLowercaseNamesStillMatch() throws {
        try write("game.rb", Array("RubyVM::InstructionSequence".utf8))
        try write("game.yarb", yarb)
        XCTAssertTrue(PsdkGame.isGameRoot(root))
    }

    func testGameRbAloneIsNotEnough() throws {
        try write("Game.rb", Array("puts 1".utf8))
        XCTAssertFalse(PsdkGame.isGameRoot(root))
    }

    func testBytecodeWithTheWrongMagicFails() throws {
        try write("Game.rb", Array("RubyVM::InstructionSequence".utf8))
        try write("Game.yarb", Array("NOPE____".utf8))
        XCTAssertFalse(PsdkGame.isGameRoot(root))
    }

    func testAShortBytecodeFileFails() throws {
        try write("Game.rb", Array("RubyVM::InstructionSequence".utf8))
        try write("Game.yarb", [0x59, 0x41])
        XCTAssertFalse(PsdkGame.isGameRoot(root))
    }

    func testAnRPGMakerFolderIsNotAPsdkGame() throws {
        try write("Game.exe", [0x4d, 0x5a])
        try write("Game.ini", Array("[Game]".utf8))
        XCTAssertFalse(PsdkGame.isGameRoot(root))
    }

    func testAMissingFolderIsNotAGameRoot() {
        XCTAssertFalse(PsdkGame.isGameRoot(root.appendingPathComponent("nothing")))
    }
}

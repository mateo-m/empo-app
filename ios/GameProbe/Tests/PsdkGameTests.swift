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

    func testLowercaseNamesDoNotMatch() throws {
        try write("game.rb", Array("RubyVM::InstructionSequence".utf8))
        try write("game.yarb", yarb)
        XCTAssertFalse(PsdkGame.isGameRoot(root))
    }

    func testGameRbAloneIsNotEnough() throws {
        try write("Game.rb", Array("puts 1".utf8))
        XCTAssertFalse(PsdkGame.isGameRoot(root))
    }

    /// Lines from the Game.rb of a release compiled with `--no-yarb`.
    func testAReleaseWithoutBytecodeIsAGameRoot() throws {
        try write(
            "Game.rb",
            Array(
                """
                PSDK_VERSION = 6716
                scripts = Marshal.load(Zlib::Inflate.inflate(File.binread('Data/Scripts.dat')))
                """.utf8))
        XCTAssertTrue(PsdkGame.isGameRoot(root))
        XCTAssertNil(PsdkGame.bytecodeVersion(root))
        XCTAssertFalse(PsdkGame.isStudioProject(root))
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

    func testAStudioProjectIsNotAGameRoot() throws {
        try write("Game.rb", Array(##"require "#{psdk_path}/scripts/ScriptLoad.rb""##.utf8))
        XCTAssertTrue(PsdkGame.isStudioProject(root))
        XCTAssertFalse(PsdkGame.isGameRoot(root))
    }

    func testAReleasedGameIsNotAStudioProject() throws {
        try write("Game.rb", Array("RubyVM::InstructionSequence".utf8))
        try write("Game.yarb", yarb)
        XCTAssertFalse(PsdkGame.isStudioProject(root))
    }

    func testReadsTheRubyVersionOfTheBytecode() throws {
        try write("Game.yarb", yarb)
        XCTAssertEqual(PsdkGame.bytecodeVersion(root), "3.0")
        // The first 16 bytes of a Game.yarb that Pokémon Studio compiled on a Mac.
        try write("Game.yarb", [0x59, 0x41, 0x52, 0x42, 3, 0, 0, 0, 2, 0, 0, 0, 0xc8, 0x8f, 0, 0])
        XCTAssertEqual(PsdkGame.bytecodeVersion(root), "3.2")
        // The first 16 bytes of a Game.yarb that Pokémon Studio compiled on Linux.
        try write("Game.yarb", [0x59, 0x41, 0x52, 0x42, 3, 0, 0, 0, 3, 0, 0, 0, 0xa0, 0x8f, 0, 0])
        XCTAssertEqual(PsdkGame.bytecodeVersion(root), "3.3")
        // The first 16 bytes of the Game.yarb of Pokémon Labyrinth, a PSDK release of 2021.
        try write("Game.yarb", [0x59, 0x41, 0x52, 0x42, 2, 0, 0, 0, 5, 0, 0, 0, 0x4e, 0xc0, 0, 0])
        XCTAssertEqual(PsdkGame.bytecodeVersion(root), "2.5")
    }

    func testAShortOrForeignFileHasNoBytecodeVersion() throws {
        try write("Game.yarb", [0x59, 0x41, 0x52, 0x42, 3, 0])
        XCTAssertNil(PsdkGame.bytecodeVersion(root))
        try write("Game.yarb", Array("NOPE____________".utf8))
        XCTAssertNil(PsdkGame.bytecodeVersion(root))
    }

    func testAMissingFolderIsNotAGameRoot() {
        XCTAssertFalse(PsdkGame.isGameRoot(root.appendingPathComponent("nothing")))
    }

    func testRenamesAFileToTheSpellingTheScriptsUse() throws {
        try makeFile("graphics/shaders/Yuki_Transition_Circular.txt")
        try writeScripts("\u{0}Ugraphics/shaders/yuki_transition_circular.txt\u{0}")

        XCTAssertEqual(
            PsdkGame.matchFileNameCase(in: root), ["graphics/shaders/yuki_transition_circular.txt"])
        XCTAssertEqual(try names(in: "graphics/shaders"), ["yuki_transition_circular.txt"])
    }

    func testLeavesAFolderWithADifferentCaseAlone() throws {
        try makeFile("graphics/Shaders/Glow.txt")
        try writeScripts("\u{0}graphics/shaders/glow.txt\u{0}")

        XCTAssertEqual(PsdkGame.matchFileNameCase(in: root), [])
        XCTAssertEqual(try names(in: "graphics/Shaders"), ["Glow.txt"])
    }

    func testAGameWithoutScriptsIsLeftAlone() throws {
        try makeFile("graphics/Title.png")
        XCTAssertEqual(PsdkGame.matchFileNameCase(in: root), [])
    }

    private func makeFile(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func names(in folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)
    }

    /// A zlib stream with one stored deflate block: the header, then
    /// the length and its complement, then the bytes.
    private func writeScripts(_ text: String) throws {
        let body = Array(text.utf8)
        let count = UInt16(body.count)
        var stream: [UInt8] = [0x78, 0x01, 0x01]
        stream += [UInt8(count & 0xff), UInt8(count >> 8), UInt8(~count & 0xff), UInt8(~count >> 8)]
        stream += body + [0, 0, 0, 0]
        try makeFile("Data/Scripts.dat")
        try Data(stream).write(to: root.appendingPathComponent("Data/Scripts.dat"))
    }
}

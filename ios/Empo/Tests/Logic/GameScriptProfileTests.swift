import XCTest

@testable import Empo

final class GameScriptProfileTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: GameScriptProfileTests.self)
        if let base = bundle.resourceURL?
            .appendingPathComponent("Fixtures/games/\(name)"),
            FileManager.default.fileExists(atPath: base.path)
        {
            return base
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/games/\(name)")
    }

    func testModernLooseScriptsRouteToRuby31() {
        let profile = GameScriptProfile.analyze(
            gameDirectory: fixtureURL("modern-loose"))
        XCTAssertEqual(profile.rubyVersion, 31)
        XCTAssertTrue(profile.modernRubyScripts)
        if case .modern = profile.grammar {
            // expected
        } else {
            XCTFail("expected modern grammar")
        }
    }

    func testLegacyLooseScriptsStayNonModern() {
        let profile = GameScriptProfile.analyze(
            gameDirectory: fixtureURL("legacy-loose"))
        XCTAssertFalse(profile.modernRubyScripts)
        if case .legacy = profile.grammar {
            // expected
        } else {
            XCTFail("expected legacy grammar")
        }
    }

    func testBundledRuby300DLLFoldsTo31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dll = dir.appendingPathComponent("x64-msvcrt-ruby300.dll")
        try Data().write(to: dll)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.rubyVersion, 31)
    }
}

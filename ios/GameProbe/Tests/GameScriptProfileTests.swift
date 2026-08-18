import XCTest

@testable import GameProbe

final class GameScriptProfileTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        #if SWIFT_PACKAGE
        guard let base = Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures/games/\(name)"),
            FileManager.default.fileExists(atPath: base.path)
        else {
            XCTFail("missing fixture: \(name)")
            return URL(fileURLWithPath: "/")
        }
        return base
        #else
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
        #endif
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

    /// An old fangame repackaged on a modern mkxp-z build: 1.8-era
    /// compiled scripts next to a Ruby 3 DLL. It runs on Ruby 3.1,
    /// but it still needs the legacy syntax transform, so the DLL
    /// must not mark the scripts modern.
    func testLegacyCompiledScriptsOutrankBundledRuby3DLL() {
        let profile = GameScriptProfile.analyze(
            gameDirectory: fixtureURL("legacy-compiled-ruby3-dll"))
        XCTAssertEqual(profile.grammar, .legacy)
        XCTAssertFalse(profile.modernRubyScripts)
        XCTAssertEqual(profile.rubyVersion, 31)
    }

    /// A custom modern engine (Pokemon Flux shape): the real scripts
    /// sit in `Data/*.fpk`, and the compiled Scripts file next to it
    /// is a legacy bootstrap. The sniffer must not classify that
    /// bootstrap, so packaging decides.
    func testPackedScriptsLeaveGrammarInconclusiveAndReadModern() {
        let profile = GameScriptProfile.analyze(
            gameDirectory: fixtureURL("packed-scripts-ruby3-dll"))
        XCTAssertEqual(profile.grammar, .inconclusive)
        XCTAssertTrue(profile.modernRubyScripts)
        XCTAssertEqual(profile.rubyVersion, 31)
    }
}

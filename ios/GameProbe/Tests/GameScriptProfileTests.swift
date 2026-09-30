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

    func testDefStatCallsDoNotReadAsEndlessDefs() {
        let profile = GameScriptProfile.analyze(
            gameDirectory: fixtureURL("legacy-loose-def-stat"))
        XCTAssertFalse(profile.modernRubyScripts)
        XCTAssertEqual(profile.grammar, .legacy)
    }

    func testRGSS2LibraryRoutesToRuby18() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "[Game]\nLibrary=RGSS202E.dll\n".write(
            to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("Game.rgss2a"))

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.rubyVersion, 18)
    }

    func testRuby19MethodsInXPScriptsRouteToRuby31Legacy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try "case x\nwhen 1: y\nend\nname = \"#{buf}\".force_encoding('UTF-8')\n".write(
            to: scripts.appendingPathComponent("Scene_Movie3.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .mixed)
        XCTAssertEqual(profile.rubyVersion, 31)
        XCTAssertFalse(profile.modernRubyScripts)
    }

    func testRuby19MethodsInVXAceScriptsStayOnRuby19() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("Scripts.rvdata2"))
        try "text = text.force_encoding('UTF-8')\n".write(
            to: scripts.appendingPathComponent("Window_Base.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).rubyVersion, 19)
    }

    func testRuby19CallInsideStringInsertRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try "# use respond_to?(:force_encoding)\ntext = \"#{value.force_encoding(\"UTF-8\")}\"\n".write(
            to: scripts.appendingPathComponent("Window_Text.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).rubyVersion, 31)
    }

    func testRuby19MethodsInCommentsStringsOrGuardsStayOnRuby18() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try """
        # call s.force_encoding on Ruby 1.9
        =begin
        Encoding::UTF_8 is not in Ruby 1.8
        =end
        print "use .force_encoding"
        s = s.force_encoding('UTF-8') if s.respond_to?(:force_encoding)
        t = t.force_encoding('UTF-8') if t.respond_to? :force_encoding
        u = u.encode(Encoding::UTF_8) if defined? Encoding
        if defined?(Encoding)
          s = s.encode(Encoding::UTF_8)
        end

        """.write(
            to: scripts.appendingPathComponent("Util.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .legacy)
        XCTAssertEqual(profile.rubyVersion, 18)
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

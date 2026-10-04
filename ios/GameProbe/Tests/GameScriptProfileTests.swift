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

    func testModernTokensInCommentsAndStringsStayOnRuby19() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("Scripts.rvdata2"))
        try """
            # * optionnal named args = font:, value:, x:, y:
            =begin
            list.filter_map { |e| e&.name }
            =end
            puts "a&.b x:, h.except(:k)"
            text = <<~DOC
              a&.b x:, h.except(:k)
            DOC
            puts "# frozen_string_literal: true", "# frozen_string_literal: true"
            puts "# frozen_string_literal: true"
            # frozen_string_literal: truest
            def a; end
            # frozen_string_literal: true
            # frozen_string_literal: true
            # frozen_string_literal: true
            # frozen_string_literal: true_or_false
            # frozen_string_literal: true, says the old doc
            raw = <<~'RAW'
              #{a&.b} #{c&.d} #{e&.f}
            RAW
            =begin
            =endless
            a&.b x:, h.except(:k)
            =end
            system `a&.b x:, h.except(:k)`
            list = %w(a&.b x:, h.except(:k))
            puts %(a&.b x:, h.except(:k))
            puts <<~A, <<~B
              one
            A
              a&.b x:, h.except(:k)
            B
            puts <<~C
            C\u{20}
              a&.b x:, h.except(:k)
            C
            """.write(
                to: scripts.appendingPathComponent("SDK_Gui.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .legacy)
        XCTAssertEqual(profile.rubyVersion, 19)
    }

    func testFrozenStringLiteralCommentsStillCountAsModern() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["A", "B", "C"] {
            try "# frozen_string_literal: true\nclass \(name); end\n".write(
                to: scripts.appendingPathComponent("\(name).rb"), atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .modern)
    }

    func testModernTokensInHeredocInterpolationCount() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
            text = <<~DOC
              #{a&.name} and #{
                b&.name } and #{c&.name}
            DOC
            """.write(to: scripts.appendingPathComponent("Main.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .modern)
    }

    func testWindowsLineEndingsCloseHeredocs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "text = <<~DOC\r\n  a&.b x:, h.except(:k)\r\nDOC\r\nputs text\r\n".write(
            to: scripts.appendingPathComponent("Main.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .legacy)
    }

    func testModuloKeepsTheRestOfTheLineAsCode() throws {
        let lines = [
            "n %= 2; a&.b; b&.c; c&.d",
            "m = n%(a&.b + b&.c + c&.d)",
            "text = \"%s\"%(a&.b + b&.c + c&.d)",
            "r = n.%(a&.b + b&.c + c&.d)",
        ]
        for line in lines {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let scripts = dir.appendingPathComponent("Scripts")
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try line.write(to: scripts.appendingPathComponent("Main.rb"), atomically: true, encoding: .utf8)

            XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .modern, line)
        }
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
        try "# use respond_to?(:force_encoding)\nx = 1 if defined?(Encoding)\n\ntext = \"#{value.force_encoding(\"UTF-8\")}\"\n".write(
            to: scripts.appendingPathComponent("Window_Text.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).rubyVersion, 31)
    }

    func testRuby19CallAfterTheSameWordInAStringRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try "warn \".force_encoding\"; value.force_encoding(\"UTF-8\")\n".write(
            to: scripts.appendingPathComponent("Window_Text.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).rubyVersion, 31)
    }

    func testRuby19CallAfterAPostfixGuardRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try """
        s = s.force_encoding('UTF-8') if s.respond_to?(:force_encoding)
        t = t.force_encoding('UTF-8')

        """.write(
            to: scripts.appendingPathComponent("Window_Text.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).rubyVersion, 31)
    }

    func testRuby19CallUnderANegatedGuardRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try """
        unless defined?(Encoding)
          value = value.force_encoding("UTF-8")
        end

        """.write(
            to: scripts.appendingPathComponent("Window_Text.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).rubyVersion, 31)
    }

    func testRuby19CallInAHeredocInsertRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try """
        message = <<~TEXT
          Name: #{value.force_encoding("UTF-8")}
        TEXT

        """.write(
            to: scripts.appendingPathComponent("Window_Text.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).rubyVersion, 31)
    }

    func testRuby19CallBeforeAGuardedStatementRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try """
        value.force_encoding("UTF-8"); log if defined?(Encoding)

        """.write(
            to: scripts.appendingPathComponent("Window_Text.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).rubyVersion, 31)
    }

    func testRuby19CallUnderAnOrGuardRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try """
        if defined?(Encoding) || fallback
          value = value.force_encoding("UTF-8")
        end

        """.write(
            to: scripts.appendingPathComponent("Window_Text.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).rubyVersion, 31)
    }

    func testRuby19CallOnAnotherReceiverThanTheGuardRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try """
        if helper.respond_to?(:force_encoding)
          text = text.force_encoding("UTF-8")
        end

        """.write(
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
          t = t.force_encoding('UTF-8')
        end
        if x
          y = 1
        elsif defined?(Encoding)
          y = y.encode(Encoding::UTF_8)
          z = z.force_encoding('UTF-8')
        end
        help = <<-EOS
        call .force_encoding on Ruby 1.9
        EOS
        if defined?(Encoding); s = s.force_encoding("UTF-8"); end
        log ";"; s = s.force_encoding("UTF-8") if defined?(Encoding)
        text = <<EOS
          EOS
        call .force_encoding on Ruby 1.9
        EOS
        if @text.respond_to?(:force_encoding)
          @text = @text.force_encoding("UTF-8")
        end
        raw = <<-'EOS'
        #{value.force_encoding("UTF-8")}
        EOS
        note = %q(use .force_encoding)
        rate = total % (Encoding::UTF_8 rescue 1) if defined? Encoding

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

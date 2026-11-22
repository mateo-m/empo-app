// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

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
        XCTAssertEqual(profile.ruby.code, 31)
        XCTAssertTrue(profile.ruby.modernScripts)
        if case .modern = profile.grammar {
            // expected
        } else {
            XCTFail("expected modern grammar")
        }
    }

    func testLegacyLooseScriptsStayNonModern() {
        let profile = GameScriptProfile.analyze(
            gameDirectory: fixtureURL("legacy-loose"))
        XCTAssertFalse(profile.ruby.modernScripts)
        if case .legacy = profile.grammar {
            // expected
        } else {
            XCTFail("expected legacy grammar")
        }
    }

    func testDefStatCallsDoNotReadAsEndlessDefs() {
        let profile = GameScriptProfile.analyze(
            gameDirectory: fixtureURL("legacy-loose-def-stat"))
        XCTAssertFalse(profile.ruby.modernScripts)
        XCTAssertEqual(profile.grammar, .legacy)
    }

    func testInputFilesHoldWhatTheScanReads() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let read = ["Game.ini", "RGSS104E.dll", "Game.rgssad", "Data/Scripts.rxdata", "Data/PluginScripts.rxdata", "Data/a.fpk", "Data/Scripts/Plugins/a.rb", "mkxp.json", "Fix/Early.rb", "Late.rb"]
        let unread = ["Save01.rxdata", "Data/Map001.rxdata", "Data/Game.ini", "Data/x.dll", "a.fpk", "Graphics/Titles/t.png", "preload.rb"]
        let files = read + unread
        for file in files {
            let url = dir.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        try "{\"preloadScript\": [\"Fix/Early.rb\", \"Missing.rb\"], \"postloadScript\": \"Late.rb\"}".write(
            to: dir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let inputs = Set(GameScriptProfile.inputFiles(gameDirectory: dir).map { $0.resolvingSymlinksInPath().path })
        let paths = files.map { dir.appendingPathComponent($0).resolvingSymlinksInPath().path }
        XCTAssertEqual(inputs, Set(paths.prefix(read.count)))
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
        XCTAssertEqual(profile.ruby.code, 19)
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
        XCTAssertEqual(profile.ruby.code, 18)
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
        XCTAssertEqual(profile.ruby.code, 31)
        XCTAssertFalse(profile.ruby.modernScripts)
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

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 19)
    }

    /// Sentry EMPO-APP-10: a Pokemon Z copy with an extra `Correction.rb`
    /// that only the game's `mkxp.json` names.
    func testBlockDefaultInAConfigPreloadScriptRoutesToRuby31Legacy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "[Game]\nLibrary=RGSS104E.dll\nScripts=Data\\Scripts.rxdata\n".write(
            to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
        try compiledScripts(["class Game_System\n  def initialize\n  end\nend\n"])
            .write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try "{\n  \"preloadScript\": [\"Correction.rb\"],\n  // \"postloadScript\": \"Late.rb\",\n}\n".write(
            to: dir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try """
            begin
              miniffi.define_singleton_method(:getWindowRect) do |hwnd = 0|
                [0, 0, 640, 480]
              end
            rescue => e
            end

            """.write(to: dir.appendingPathComponent("Correction.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .mixed)
        XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: true))
    }

    /// Sentry EMPO-APP-54: Pokemon Dark Light stops on Ruby 1.8 with
    /// "undefined method `prepend' for Scene_Jukebox:Class".
    func testModulePrependInAConfigPreloadScriptRoutesToRuby31Legacy() throws {
        for call in [
            "Scene_Jukebox.prepend(Module.new do\n  def update; end\nend)",
            "class Scene_Jukebox\n  prepend JukeboxText\nend",
            "class Scene_Jukebox; prepend JukeboxText; end",
            "class Scene_Jukebox\n  prepend(::JukeboxText)\nend",
            "Scene_Jukebox.prepend(JukeboxText) if Scene_Jukebox.respond_to?(:force_encoding)",
            "RPG::Cache.prepend(JukeboxText) if Cache.respond_to?(:prepend)",
        ] {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("scripts/preload"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try "[Game]\nLibrary=RGSS104E.dll\nScripts=Data\\Scripts.rxdata\n".write(
                to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
            try compiledScripts(["class Scene_Jukebox\n  def update\n  end\nend\n"])
                .write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
            try "{\"preloadScript\": [\"scripts/preload/92_jukebox_text.rb\"]}".write(
                to: dir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
            try "\(call)\n".write(
                to: dir.appendingPathComponent("scripts/preload/92_jukebox_text.rb"), atomically: true,
                encoding: .utf8)

            let profile = GameScriptProfile.analyze(gameDirectory: dir)
            XCTAssertEqual(profile.grammar, .mixed, call)
            XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: true), call)
        }
    }

    func testBlockDefaultInAConfigScriptBesideAnEncryptedCoreRulesOutRuby18() throws {
        for (archive, ruby) in [("Game.rgssad", GameScriptProfile.Ruby.ruby31(convertLegacy: true)), ("Game.rgss3a", .ruby19)] {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try Data().write(to: dir.appendingPathComponent(archive))
            try "{\"preloadScript\": \"Correction.rb\"}".write(
                to: dir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
            try "list.each do |hwnd = 0|\nend\n".write(
                to: dir.appendingPathComponent("Correction.rb"), atomically: true, encoding: .utf8)

            let profile = GameScriptProfile.analyze(gameDirectory: dir)
            XCTAssertEqual(profile.grammar, .mixed, archive)
            XCTAssertEqual(profile.ruby, ruby, archive)
        }
    }

    func testBlockDefaultInAConfigScriptOutranksABundledRuby18DLL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("msvcrt-ruby187.dll"))
        try compiledScripts(["x = 1\n"]).write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try "{\"preloadScript\": \"Correction.rb\"}".write(
            to: dir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try "list.each do |hwnd = 0|\nend\n".write(
            to: dir.appendingPathComponent("Correction.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby, .ruby31(convertLegacy: true))
    }

    func testBlockDefaultInAConfigScriptBesideAPackedArchiveRulesOutRuby18() throws {
        let dir = try packedGame(plugins: ["x = 1\n"])
        defer { try? FileManager.default.removeItem(at: dir) }

        try "[Game]\nLibrary=RGSS104E.dll\n".write(
            to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
        try "{\"preloadScript\": \"Correction.rb\"}".write(
            to: dir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try "list.each do |hwnd = 0|\nend\n".write(
            to: dir.appendingPathComponent("Correction.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .mixed)
        XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: false))
    }

    func testRuby19PluginCallsBesideAPackedArchiveKeepModernScripts() throws {
        let dir = try packedGame(plugins: ["s.force_encoding('UTF-8')\n"])
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("x64-msvcrt-ruby310.dll"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby, .ruby31(convertLegacy: false))
    }

    func testRuby19PluginCallsBesideAPackedArchiveIgnoreItsVXAceScriptsFile() throws {
        let dir = try packedGame(plugins: ["s.force_encoding('UTF-8')\n"])
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.moveItem(
            at: dir.appendingPathComponent("Data/Scripts.rxdata"),
            to: dir.appendingPathComponent("Data/Scripts.rvdata2"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby, .ruby31(convertLegacy: false))
    }

    func testRuby19CallsOutrankABundledRuby18DLL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("msvcrt-ruby187.dll"))
        try compiledScripts(["x = 1\n", "s.force_encoding('UTF-8')\n"])
            .write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .mixed)
        XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: true))
    }

    func testRuby19PluginCallsBesideAnEncryptedCoreKeepTheRuby3RuntimeChoice() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("Game.rgssad"))
        try Data("stub ruby 3.1.0p0 (2021-12-25) [x64-mingw32]".utf8)
            .write(to: dir.appendingPathComponent("x64-msvcrt-ruby310.dll"))
        try pluginScripts(["s.force_encoding('UTF-8')\n"])
            .write(to: dir.appendingPathComponent("Data/PluginScripts.rxdata"))

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .mixed)
        XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: false))
    }

    func testMixedLooseScriptsBesideAPackedArchiveKeepTheLegacyTransform() throws {
        let dir = try packedGame(plugins: ["x = 1\n"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try "case x\nwhen 1: y\nend\ns.force_encoding('UTF-8')\n".write(
            to: scripts.appendingPathComponent("Main.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .mixed)
        XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: true))
    }

    func testBlockDefaultOverTwoLinesRoutesToRuby31Legacy() throws {
        for source in [
            "list.each do |first,\n  hwnd = 0|\nend\n", "list.each { |hwnd =\n  0| hwnd }\n", "list.each do\n  |hwnd = 0|\nend\n",
            "list.each do # one window\n  |hwnd = 0|\nend\n",
        ] {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try compiledScripts([source]).write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))

            XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby, .ruby31(convertLegacy: true), source)
        }
    }

    func testAConfigScriptInALooseScriptFolderCountsOnce() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("Scripts.rxdata"))
        try "a = b&.c\nh.except(:k)\n".write(
            to: scripts.appendingPathComponent("Fix.rb"), atomically: true, encoding: .utf8)
        try "{\"preloadScript\": [\"Scripts/Fix.rb\"]}".write(
            to: dir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .legacy)
    }

    func testAConfigScriptListedTwiceCountsOnce() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try compiledScripts(["x = 1\n"]).write(to: dir.appendingPathComponent("Scripts.rxdata"))
        try "a = b&.c\nh.except(:k)\n".write(
            to: dir.appendingPathComponent("Fix.rb"), atomically: true, encoding: .utf8)
        try "{\"preloadScript\": [\"Fix.rb\"], \"postloadScript\": \"./Fix.rb\"}".write(
            to: dir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .legacy)
    }

    func testBlockParametersWithoutADefaultStayOnRuby18() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try compiledScripts([
            "list.each { |a| a = 1 }\nlist.each do |a, b| b == a end\nlist.each { |a| a |= 1 }\n",
            "list.select { |a| a != 0 || a <= 2 }\n# list.each do |a = 0| end\nputs \"{ |a = 0| }\"\n",
        ]).write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .legacy)
        XCTAssertEqual(profile.ruby, .ruby18)
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

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
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

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
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

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
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

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
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

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
    }

    func testRuby19CallAfterAShiftOrARegexRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        // `i<<x` is a shift and `/<<r>>/` a regex, not heredocs that
        // end at a line "x", "r", or "tag".
        try """
        ret|=(i<<x)
        mask = (1<<index)
        basedmg=basedmg<<shift
        mask = value <<token
        ret.gsub!(/<<r>>/,"\\r")
        tags = text.scan /<<tag>>/
        half = width/2
        third = width /3; str.force_encoding('UTF-8')
        names = %w(
        tag
        )

        """.write(
            to: scripts.appendingPathComponent("File_Mixins.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
    }

    func testRuby19CallAfterAShiftWithAnEndLineInALaterScriptRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A heredoc ends in its own script.
        try compiledScripts([
            "mask = value <<token\nstr.force_encoding('UTF-8')\n",
            "names = %w(\ntoken\n)\n",
        ]).write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
    }

    func testRuby19CallInAHeredocAfterAShiftOnTheSameLineRoutesToRuby18() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try compiledScripts([
            "text = value <<shift + <<'END'\nstr.force_encoding('UTF-8')\nEND\n"
        ]).write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 18)
    }

    func testRuby19CallAfterACommentInAWindowsScriptRoutesToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try "# Scene_Movie\r\ncase to\r\nwhen 65001; str.force_encoding('UTF-8')\r\nend\r\n".write(
            to: scripts.appendingPathComponent("Scene_Movie.rb"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
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

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
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

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
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

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31)
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
        # Scene_Map.prepend(MapText)
        def prepend(item)
          print "prepend MapText"
        end
        key = :prepend
        def self.prepend(item)
        end
        def  self.prepend(item)
        end
        def Scene_Map.prepend(item)
        end
        def RPG::Cache.prepend(item)
        end
        notes = <<-EOS
        prepend MapText
        EOS
        Scene_Map.prepend(MapText) if Scene_Map.respond_to?(:prepend)
        RPG::Cache.prepend(MapText) if RPG::Cache.respond_to?(:prepend)
        if respond_to?(:prepend)
          prepend MapText
        end
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
        if defined?(Encoding) && mode == :utf8
          s = s.force_encoding('UTF-8')
        end
        if defined?(Encoding) != nil
          s = s.force_encoding('UTF-8')
        end
        if s.respond_to?(:force_encoding) == true
          s = s.force_encoding('UTF-8')
        end

        """.write(
            to: scripts.appendingPathComponent("Util.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .legacy)
        XCTAssertEqual(profile.ruby.code, 18)
    }

    /// Sentry EMPO-APP-V: Pokemon Xenoverse ships Zeus81's Bitmap Export
    /// and Video Player, which call 1.9 methods only when `vxace?`.
    func testRuby19CallsUnderTheVXAceCheckStayOnRuby18() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Data/Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "[Game]\nLibrary=RGSS102E.dll\nScripts=Data\\Scripts.rxdata\n".write(
            to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try """
        def xp?() false end; alias vx? xp?; alias vxace? xp?
        RUBY_VERSION == '1.8.1' ? defined?(Hangup) ?
        def xp?() true  end : def vx?() true  end : def vxace?() true  end
          def _dump(level)
            get_data_ptr do |data|
              dump = Marshal.dump([width, height, Zlib::Deflate.deflate(data, 9)])
              dump.force_encoding('UTF-8') if vxace?
              dump
            end
          end

        """.write(
            to: scripts.appendingPathComponent("247_BitmapExporter.rb"), atomically: true, encoding: .utf8)
        try """
            def self.encode(str, from, to, dchar=nil, dflag=nil)
              case to
              when 20127; str.force_encoding('US-ASCII')
              # UTF-8
              when 65001; str.force_encoding('UTF-8')
              when    -1; str.force_encoding('UTF-16LE')
              end if vxace?
              str
            end

        """.replacingOccurrences(of: "\n", with: "\r\n").write(
            to: scripts.appendingPathComponent("238_ZeusVideoPlayer.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .legacy)
        XCTAssertEqual(profile.ruby, .ruby18)
    }

    func testRuby19CallsInABlockThatEndsWithAnotherConditionRouteToRuby31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        for source in [
            "case to\nwhen 1; s.force_encoding('UTF-8')\nend if s\n",
            "begin\n  s.force_encoding('UTF-8')\nend unless vxace?\n",
            "def encode(s)\n  s.force_encoding('UTF-8')\n    end if vxace?\n",
            "s.force_encoding('UTF-8')\n  case to\n  when 1; x\nend if vxace?\n",
            "def f(s)\n  s.force_encoding('UTF-8')\n  whenever = [1].each do |v|\n    v\n  end if vxace?\nend\n",
            "if vxace? == false\n  s.force_encoding('UTF-8')\nend\n",
            "if vxace?() != true\n  s.force_encoding('UTF-8')\nend\n",
            "s.force_encoding('UTF-8') if (vxace?) == false\n",
            "if (vxace?()) != true\n  s.force_encoding('UTF-8')\nend\n",
            "case mode\nwhen 1; s.force_encoding('UTF-8')\nwhen 2; begin\n  work\nend if vxace?\nend\n",
        ] {
            try source.write(to: scripts.appendingPathComponent("Text.rb"), atomically: true, encoding: .utf8)
            XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby.code, 31, source)
        }
    }

    func testRuby19CallOnTheEndLineOfABlockCommentStaysOnRuby18() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let scripts = dir.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try "=begin\n=end s.force_encoding('UTF-8')\nx = 1\n".write(
            to: scripts.appendingPathComponent("Util.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .legacy)
        XCTAssertEqual(profile.ruby, .ruby18)
    }

    func testBundledRuby300DLLFoldsTo31() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dll = dir.appendingPathComponent("x64-msvcrt-ruby300.dll")
        try Data().write(to: dll)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.ruby.code, 31)
    }

    func testModernScriptsOutrankABundledRuby18DLL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("msvcrt-ruby187.dll"))
        try pluginScripts([
            "a = b&.c\n", "list.filter_map { |x| x }\n", "h.except(:k)\n",
        ]).write(to: dir.appendingPathComponent("Data/PluginScripts.rxdata"))

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .modern)
        XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: false))
    }

    /// An old fangame repackaged on a modern mkxp-z build: 1.8-era
    /// compiled scripts next to a Ruby 3 DLL. It runs on Ruby 3.1,
    /// but it still needs the legacy syntax transform, so the DLL
    /// must not mark the scripts modern.
    func testLegacyCompiledScriptsOutrankBundledRuby3DLL() {
        let profile = GameScriptProfile.analyze(
            gameDirectory: fixtureURL("legacy-compiled-ruby3-dll"))
        XCTAssertEqual(profile.grammar, .legacy)
        XCTAssertFalse(profile.ruby.modernScripts)
        XCTAssertEqual(profile.ruby.code, 31)
    }

    /// A custom modern engine (Pokemon Flux shape): the real scripts
    /// sit in `Data/*.fpk`, and the compiled Scripts file next to it
    /// is a legacy bootstrap. The sniffer must not classify that
    /// bootstrap, so packaging decides.
    func testPackedScriptsLeaveGrammarInconclusiveAndReadModern() {
        let profile = GameScriptProfile.analyze(
            gameDirectory: fixtureURL("packed-scripts-ruby3-dll"))
        XCTAssertEqual(profile.grammar, .inconclusive)
        XCTAssertTrue(profile.ruby.modernScripts)
        XCTAssertEqual(profile.ruby.code, 31)
    }

    func testModernPluginCodeOutranksALegacyScriptsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try compiledScripts(["str.force_encoding('UTF-8')\n"])
            .write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try pluginScripts([
            "a = b&.c\n", "list.filter_map { |x| x }\n", "h.except(:k)\n",
        ]).write(to: dir.appendingPathComponent("Data/PluginScripts.rxdata"))

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .modern)
        XCTAssertTrue(profile.ruby.modernScripts)
        XCTAssertEqual(profile.ruby.code, 31)
    }

    func testModernPluginCodeCountsWithoutAScriptsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try pluginScripts([
            "a = b&.c\n", "list.filter_map { |x| x }\n", "h.except(:k)\n",
        ]).write(to: dir.appendingPathComponent("Data/PluginScripts.rxdata"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .modern)
    }

    func testLegacyPluginCodeAloneIsInconclusive() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try pluginScripts(["x = 1\n"])
            .write(to: dir.appendingPathComponent("Data/PluginScripts.rxdata"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .inconclusive)
    }

    func testNegativeFloatLengthIsInconclusive() throws {
        // An outer array of 1, an inner array of 3, then a float whose
        // length prefix `ff 00` reads as -256. Data keeps 14 bytes or
        // less inline, and an inline read before the start does not
        // trap, so the padding makes the file long enough to crash.
        let bytes = Data([0x04, 0x08, 0x5b, 0x06, 0x5b, 0x08, 0x66, 0xff, 0x00] + [UInt8](repeating: 0x30, count: 300))
        for name in ["PluginScripts.rxdata", "Scripts.rxdata"] {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try bytes.write(to: dir.appendingPathComponent("Data/\(name)"))

            XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .inconclusive, name)
        }
    }

    func testDeeplyNestedArraysAreInconclusive() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let header: [UInt8] = [0x04, 0x08, 0x5b, 0x06, 0x5b, 0x08]
        let nested = Array(repeating: [UInt8]([0x5b, 0x06]), count: 200_000).joined()
        try Data(header + nested)
            .write(to: dir.appendingPathComponent("Data/PluginScripts.rxdata"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .inconclusive)
    }

    func testModernPluginCodeOutranksLegacyLooseScripts() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data/Scripts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "str.force_encoding('UTF-8')\n".write(
            to: dir.appendingPathComponent("Data/Scripts/Main.rb"), atomically: true, encoding: .utf8)
        try pluginScripts([
            "a = b&.c\n", "list.filter_map { |x| x }\n", "h.except(:k)\n",
        ]).write(to: dir.appendingPathComponent("Data/PluginScripts.rxdata"))

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .modern)
        XCTAssertEqual(profile.ruby.code, 31)
    }

    func testModernPluginCodeCountsBesideAPackedArchive() throws {
        let dir = try packedGame(plugins: [
            "a = b&.c\n", "list.filter_map { |x| x }\n", "h.except(:k)\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .modern)
        XCTAssertEqual(profile.ruby.code, 31)
    }

    func testLegacyPluginCodeBesideAPackedArchiveIsInconclusive() throws {
        let dir = try packedGame(plugins: ["x = 1\n"])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .inconclusive)
    }

    func testPluginSourceWithANegativeIvarCountIsSkipped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 0xfa is the Marshal encoding of -1.
        let plugin: [UInt8] = [0x04, 0x08, 0x5b, 0x06, 0x5b, 0x08]
            + marshalString(Array("Plugin".utf8)) + [0x7b, 0x00, 0x5b, 0x06, 0x5b, 0x07]
            + marshalString(Array("0.rb".utf8)) + [0x49] + marshalString(deflated("a = b&.c\n")) + [0xfa]
        try Data(plugin).write(to: dir.appendingPathComponent("Data/PluginScripts.rxdata"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .inconclusive)
    }

    private func packedGame(plugins: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Data/Data_0.fpk"))
        try compiledScripts(["str.force_encoding('UTF-8')\n"])
            .write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try pluginScripts(plugins).write(to: dir.appendingPathComponent("Data/PluginScripts.rxdata"))
        return dir
    }

    private func marshalString(_ bytes: [UInt8]) -> [UInt8] { [0x22, UInt8(bytes.count + 5)] + bytes }

    /// One stored deflate block, which adds 11 bytes. A one-byte Marshal
    /// length holds at most 122, so a source has at most 111.
    private func deflated(_ source: String) -> [UInt8] {
        let body = Array(source.utf8)
        precondition(body.count <= 111, "the source is too long for a one-byte length")
        let count = UInt16(body.count)
        return [0x78, 0x01, 0x01, UInt8(count & 0xff), UInt8(count >> 8), UInt8(~count & 0xff), UInt8(~count >> 8)]
            + body + [0, 0, 0, 0]
    }

    /// A Marshal array of `[id, title, zlib source]` entries.
    private func compiledScripts(_ sources: [String]) -> Data {
        var data: [UInt8] = [0x04, 0x08, 0x5b, UInt8(sources.count + 5)]
        for (id, source) in sources.enumerated() {
            data += [0x5b, 0x08, 0x69, UInt8(id + 6)] + marshalString(Array("Script".utf8))
                + marshalString(deflated(source))
        }
        return Data(data)
    }

    /// One plugin, `[name, {}, [[path, zlib source], ...]]`, in a Marshal array.
    private func pluginScripts(_ sources: [String]) -> Data {
        var data: [UInt8] = [0x04, 0x08, 0x5b, 0x06, 0x5b, 0x08]
            + marshalString(Array("Plugin".utf8)) + [0x7b, 0x00, 0x5b, UInt8(sources.count + 5)]
        for (index, source) in sources.enumerated() {
            data += [0x5b, 0x07] + marshalString(Array("\(index).rb".utf8)) + marshalString(deflated(source))
        }
        return Data(data)
    }
}

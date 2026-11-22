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

    /// Sentry EMPO-APP-13: Pokemon Rejuvenation 13.5 stops with "unexpected
    /// symbol literal" at `def getRoll(update_roll:true, isDebuff:false)`.
    /// The legacy transform cannot parse a keyword parameter.
    func testKeywordParametersRouteToModernRuby31() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data/Scripts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "[Game]\nLibrary=RGSS104E.dll\nScripts=Data\\Scripts.rxdata\n".write(
            to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        // The scan reads `Scripts/` first, so this 4.5 MB data table
        // comes before the code.
        try String(repeating: "MOVEHASH[:TACKLE] = [1, 2, 3]\n", count: 150_000).write(
            to: dir.appendingPathComponent("Scripts/Moves.rb"), atomically: true, encoding: .utf8)
        try """
        class PokeBattle_Battler
          def getRoll(update_roll:true, isDebuff:false)
          end
          def pbReduceHP(amt, anim: false, registerDamage: true)
          end
          def self.pbFaint(showMessage: true)
          end
        end
        ItemHandlers::UseOnPokemon.add(:RARECANDY, proc { |item, pokemon, scene, amount = 1|
        })

        """.write(to: dir.appendingPathComponent("Data/Scripts/Battler.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .modern)
        XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: false))
    }

    func testKeywordParametersAfterBracketDefaultsRouteToModernRuby31() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try """
        def canChangeFE?(newfield = [], ignoreOverlays: false)
        end
        def show(values = [1], opts = {}, enabled: true)
        end
        def pick(value = default_value(x), enabled: true)
        end

        """.write(to: dir.appendingPathComponent("Scripts/Field.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .modern)
        XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: false))
    }

    func testDefaultsThatLookLikeKeywordParametersStayLegacy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        // Two real modern tokens, so one false hit makes three.
        try """
        a = b&.c
        h.except(:k)
        def initialize(x, opts = {:a => 1})
        end
        def pick(a = b ? c:d)
        end
        def kind(a = Game_Battler::NORMAL)
        end
        def show(a, b = {c: 1})
        end
        def show(a, b = {c: 1, d: 2})
        end
        def kind(a = g(1, Game_Battler::NORMAL))
        end
        def call(a = g(1, k: 2))
        end
        def list(x, a = [1, k: 2])
        end
        def pass(a, b = h(x, y: 1))
        end
        # def getRoll(update_roll:true, isDebuff:false)
        help = "def getRoll(update_roll:true, isDebuff:false)"
        x = cond ? a:b

        """.write(to: dir.appendingPathComponent("Scripts/Util.rb"), atomically: true, encoding: .utf8)

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .legacy)
        XCTAssertEqual(profile.ruby.code, 18)
    }

    func testInputFilesHoldWhatTheScanReads() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let read = ["Game.ini", "Uranium.ini", "RGSS104E.dll", "Game.rgssad", "Data/Scripts.rxdata", "Data/PluginScripts.rxdata", "Data/a.fpk", "Data/Scripts/Plugins/a.rb", "mkxp.json", "Fix/Early.rb", "Late.rb"]
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
        for (archive, scripts, ruby) in [
            ("Game.rgssad", "Scripts.rxdata", GameScriptProfile.Ruby.ruby31(convertLegacy: true)),
            ("Game.rgss3a", "Scripts.rvdata2", .ruby19),
        ] {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try "[Game]\nScripts=Data\\\(scripts)\n".write(
                to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
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

    func testModernScriptsInAnEncryptedArchiveRouteToRuby31() throws {
        let modern = compiledScripts(["a = b&.c\n", "list.filter_map { |x| x }\n", "h.except(:k)\n"])
        for (archive, version, scripts) in [
            ("Game.rgssad", 1, "Scripts.rxdata"), ("Game.rgss2a", 1, "Scripts.rvdata"), ("Game.rgss3a", 3, "Scripts.rvdata2"),
        ] {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try "[Game]\nScripts=Data\\\(scripts)\n".write(
                to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
            try rgssArchive(
                version: version,
                files: [("Data\\EditorScripts.rxdata", compiledScripts(["x = 1\n"])), ("Data\\\(scripts)", modern)]
            ).write(to: dir.appendingPathComponent(archive))

            let profile = GameScriptProfile.analyze(gameDirectory: dir)
            XCTAssertEqual(profile.grammar, .modern, archive)
            XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: false), archive)
        }
    }

    func testLegacyScriptsInAnEncryptedArchiveKeepTheArchiveRuby() throws {
        for (archive, version, scripts, ruby) in [
            ("Game.rgssad", 1, "Scripts.rxdata", GameScriptProfile.Ruby.ruby18), ("Game.rgss3a", 3, "Scripts.rvdata2", .ruby19),
        ] {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try "[Game]\nScripts=Data\\\(scripts)\n".write(
                to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
            try rgssArchive(version: version, files: [("Data\\\(scripts)", compiledScripts(["x = 1\n"]))])
                .write(to: dir.appendingPathComponent(archive))

            let profile = GameScriptProfile.analyze(gameDirectory: dir)
            XCTAssertEqual(profile.grammar, .legacy, archive)
            XCTAssertEqual(profile.ruby, ruby, archive)
        }
    }

    /// Pokemon Insurgence 2.0.1 keeps its Ruby 3.1 port of 1.8 scripts
    /// only in an encrypted `Game.rgssad`.
    func testRuby19CallsInAnEncryptedRGSS1ArchiveRouteToRuby31Legacy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try rgssArchive(version: 1, files: [("Data\\Scripts.rxdata", compiledScripts(["s.force_encoding('UTF-8')\n"]))])
            .write(to: dir.appendingPathComponent("Game.rgssad"))

        let profile = GameScriptProfile.analyze(gameDirectory: dir)
        XCTAssertEqual(profile.grammar, .mixed)
        XCTAssertEqual(profile.ruby, .ruby31(convertLegacy: true))
    }

    func testScriptsInTheArchiveWinOverALooseScriptsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try compiledScripts(["x = 1\n"]).write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try rgssArchive(
            version: 1, files: [("Data\\Scripts.rxdata", compiledScripts(["a&.b\n", "c&.d\n", "e&.f\n"]))]
        ).write(to: dir.appendingPathComponent("Game.rgssad"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .modern)
    }

    func testALooseScriptsFileBesideAnArchiveDoesNotPickTheRuby() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "[Game]\nScripts=Data\\Scripts.rvdata2\n".write(
            to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
        try compiledScripts(["x = 1\n"]).write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try rgssArchive(version: 3, files: [("Data\\Scripts.rvdata2", compiledScripts(["y = 2\n"]))])
            .write(to: dir.appendingPathComponent("Game.rgss3a"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby, .ruby19)
    }

    func testTheArchiveFollowsTheRGSSVersionOfTheEngine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "[Game]\nScripts=Data\\Scripts.rvdata2\n".write(
            to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
        try rgssArchive(
            version: 1, files: [("Data\\Scripts.rvdata2", compiledScripts(["a&.b\n", "c&.d\n", "e&.f\n"]))]
        ).write(to: dir.appendingPathComponent("Game.rgssad"))
        try rgssArchive(version: 3, files: [("Data\\Scripts.rvdata2", compiledScripts(["x = 1\n"]))])
            .write(to: dir.appendingPathComponent("Game.rgss3a"))
        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .legacy)
        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby, .ruby19)

        try #"{"rgssVersion": 1}"#.write(
            to: dir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .modern)
    }

    func testAnArchiveThatTheEngineDoesNotMountIsNotRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try compiledScripts(["x = 1\n"]).write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        let modern = compiledScripts(["a&.b\n", "c&.d\n", "e&.f\n"])
        try rgssArchive(version: 1, files: [("Data\\Scripts.rxdata", modern)])
            .write(to: dir.appendingPathComponent("Backup.rgssad"))
        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .legacy)

        let ini = "[Game]\nLibrary=RGSS102E.dll\nScripts=Data\\Scripts.rxdata\n"
        try ini.write(to: dir.appendingPathComponent("Backup.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .modern)

        try ini.write(to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .legacy)
    }

    func testTheArchiveFollowsTheExecNameOfMkxpJson() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["Game", "Uranium"] {
            try "[Game]\nScripts=Data\\Scripts.rxdata\n".write(
                to: dir.appendingPathComponent("\(name).ini"), atomically: true, encoding: .utf8)
        }
        try rgssArchive(version: 1, files: [("Data\\Scripts.rxdata", compiledScripts(["x = 1\n"]))])
            .write(to: dir.appendingPathComponent("Game.rgssad"))
        try rgssArchive(
            version: 1, files: [("Data\\Scripts.rxdata", compiledScripts(["a&.b\n", "c&.d\n", "e&.f\n"]))]
        ).write(to: dir.appendingPathComponent("Uranium.rgssad"))
        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .legacy)

        try #"{"execName": "Uranium"}"#.write(
            to: dir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .modern)
    }

    func testTheArchiveReadsTheScriptsPathOfGameIni() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "[Game]\nScripts=Data\\Main.rxdata\n".write(
            to: dir.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
        try rgssArchive(
            version: 1,
            files: [
                ("Data\\Scripts.rxdata", compiledScripts(["x = 1\n"])),
                ("Data\\Main.rxdata", compiledScripts(["a&.b\n", "c&.d\n", "e&.f\n"])),
            ]
        ).write(to: dir.appendingPathComponent("Game.rgssad"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .modern)
    }

    func testAnArchiveThatTheEngineDoesNotMountDoesNotPickTheRuby() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try compiledScripts(["x = 1\n"]).write(to: dir.appendingPathComponent("Data/Scripts.rxdata"))
        try rgssArchive(version: 1, files: [("Data\\Scripts.rxdata", compiledScripts(["y = 2\n"]))])
            .write(to: dir.appendingPathComponent("Game.rgssad"))
        try rgssArchive(version: 3, files: []).write(to: dir.appendingPathComponent("Backup.rgss3a"))

        XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).ruby, .ruby18)
    }

    func testCutArchivesAreInconclusive() throws {
        let full = rgssArchive(version: 1, files: [("Data\\Scripts.rxdata", compiledScripts(["a&.b\n"]))])
        let full3 = rgssArchive(version: 3, files: [("Data\\Scripts.rxdata", compiledScripts(["a&.b\n"]))])
        for bytes in [full.prefix(20), full.prefix(full.count - 3), full3.prefix(30), full3.prefix(full3.count - 3), Data("RGSSAD\0\u{2}".utf8)] {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try Data(bytes).write(to: dir.appendingPathComponent("Game.rgssad"))

            XCTAssertEqual(GameScriptProfile.analyze(gameDirectory: dir).grammar, .inconclusive)
        }
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

    /// XOR is its own inverse, so the decrypt steps also encrypt.
    private func rgssArchive(version: Int, files: [(name: String, data: Data)]) -> Data {
        func next(_ key: inout UInt32) -> UInt32 {
            defer { key = key &* 7 &+ 3 }
            return key
        }
        func le(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) } }
        func encrypt(_ data: Data, key: UInt32) -> [UInt8] {
            var key = key
            return data.enumerated().map { index, byte in
                defer { if index % 4 == 3 { key = key &* 7 &+ 3 } }
                return byte ^ UInt8(truncatingIfNeeded: key >> (8 * UInt32(index % 4)))
            }
        }
        var out = Array("RGSSAD\0".utf8) + [UInt8(version)]
        if version == 1 {
            var key: UInt32 = 0xDEAD_CAFE
            for file in files {
                let name = Array(file.name.utf8)
                out += le(UInt32(name.count) ^ next(&key))
                out += name.map { $0 ^ UInt8(truncatingIfNeeded: next(&key)) }
                out += le(UInt32(file.data.count) ^ next(&key))
                out += encrypt(file.data, key: key)
            }
            return Data(out)
        }
        let base: UInt32 = 0x1234_5678
        let key = base &* 9 &+ 3
        out += le(base)
        let table = files.reduce(0) { $0 + 16 + $1.name.utf8.count } + 4
        var offset = out.count + table
        var bodies: [UInt8] = []
        for (index, file) in files.enumerated() {
            let name = Array(file.name.utf8)
            let dataKey = UInt32(0xC0FFEE + index)
            out += le(UInt32(offset) ^ key) + le(UInt32(file.data.count) ^ key)
            out += le(dataKey ^ key) + le(UInt32(name.count) ^ key)
            out += name.enumerated().map { $1 ^ UInt8(truncatingIfNeeded: key >> (8 * UInt32($0 % 4))) }
            bodies += encrypt(file.data, key: dataKey)
            offset += file.data.count
        }
        return Data(out + le(key) + bodies)
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

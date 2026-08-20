import XCTest

@testable import GameProbe

final class GameINITests: XCTestCase {

    /// Game directory populated with the given ini files. The caller
    /// removes it via the returned defer-friendly URL.
    private func makeGameDir(inis: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameINITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, contents) in inis {
            try contents.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func writeINI(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let iniURL = dir.appendingPathComponent("Game.ini")
        try contents.write(to: iniURL, atomically: true, encoding: .utf8)
        return iniURL
    }

    func testParsesTitleWithSpaceBeforeEquals() throws {
        let iniURL = try writeINI(
            """
            [Game]
            title =BLACK SOULS
            """)
        XCTAssertEqual(
            GameINI.parseINIValue(in: iniURL, section: "game", key: "title"),
            "BLACK SOULS")
    }

    func testParsesTitleWithoutSpacesAroundEquals() throws {
        let iniURL = try writeINI(
            """
            [Game]
            Title=Pokemon Reborn
            """)
        XCTAssertEqual(
            GameINI.parseINIValue(in: iniURL, section: "game", key: "title"),
            "Pokemon Reborn")
    }

    func testParsesRTPWithSpaceBeforeEquals() throws {
        let iniURL = try writeINI(
            """
            [Game]
            rtp =RPGVXAce
            """)
        XCTAssertEqual(
            GameINI.parseINIValue(in: iniURL, section: "game", key: "rtp"),
            "RPGVXAce")
    }

    func testParsesScriptsPathWithBackslashes() throws {
        let iniURL = try writeINI(
            """
            [Game]
            scripts =Data\\Scripts.rvdata2
            """)
        XCTAssertEqual(
            GameINI.parseINIValue(in: iniURL, section: "game", key: "scripts"),
            "Data\\Scripts.rvdata2")
    }

    func testIgnoresOtherSections() throws {
        let iniURL = try writeINI(
            """
            [Options]
            title=Wrong Section
            [Game]
            title=Right Section
            """)
        XCTAssertEqual(
            GameINI.parseINIValue(in: iniURL, section: "game", key: "title"),
            "Right Section")
    }

    // MARK: - Directory scan

    func testGameIniWinsOverOtherInis() throws {
        let dir = try makeGameDir(inis: [
            "Game.ini": "[Game]\ntitle=Canonical",
            "AAA.ini": "[Game]\ntitle=Impostor",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(
            GameINI.parseINIValue(at: dir, section: "game", key: "title"),
            "Canonical")
    }

    func testLowercaseGameIniStillWinsOverOtherInis() throws {
        // The primary pick matches "game.ini" without case from the
        // directory listing, so priority is identical on
        // case-sensitive and case-insensitive filesystems. "aaa.ini"
        // sorts first and must still lose.
        let dir = try makeGameDir(inis: [
            "game.ini": "[Game]\ntitle=Canonical",
            "aaa.ini": "[Game]\ntitle=Impostor",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(
            GameINI.parseINIValue(at: dir, section: "game", key: "title"),
            "Canonical")
    }

    func testEmptyValueInFirstIniDoesNotEndTheScan() throws {
        // AAA.ini declares the key with an EMPTY value. That is not
        // a hit, so the scan must continue to BBB.ini.
        let dir = try makeGameDir(inis: [
            "AAA.ini": "[Game]\ntitle=",
            "BBB.ini": "[Game]\ntitle=Real Title",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(
            GameINI.parseINIValue(at: dir, section: "game", key: "title"),
            "Real Title")
    }

    func testEmptyValueLineDoesNotEndTheFileScan() throws {
        // Within ONE file, an empty `title=` line must not stop the
        // line scan before a later line that carries the value.
        let iniURL = try writeINI(
            """
            [Game]
            title=
            Title=Real
            """)
        XCTAssertEqual(
            GameINI.parseINIValue(in: iniURL, section: "game", key: "title"),
            "Real")
    }

    func testGameIniWithoutValueDoesNotEndTheScan() throws {
        let dir = try makeGameDir(inis: [
            "Game.ini": "[Game]\nscripts=Data\\Scripts.rxdata",
            "Uranium.ini": "[Game]\ntitle=Pokemon Uranium",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(
            GameINI.parseINIValue(at: dir, section: "game", key: "title"),
            "Pokemon Uranium")
    }

    func testScanIsValueSeekingNotFirstFile() throws {
        // AAA.ini sorts first but lacks the value. The scan must
        // continue to BBB.ini instead of stopping at the first file.
        let dir = try makeGameDir(inis: [
            "AAA.ini": "[Options]\nfullscreen=1",
            "BBB.ini": "[Game]\ntitle=Found It",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(
            GameINI.parseINIValue(at: dir, section: "game", key: "title"),
            "Found It")
    }

    func testScanPicksTheFirstIniInSortedNameOrder() throws {
        let dir = try makeGameDir(inis: [
            "b.ini": "[Game]\ntitle=Second",
            "a.ini": "[Game]\ntitle=First",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(
            GameINI.parseINIValue(at: dir, section: "game", key: "title"),
            "First")
    }

    func testDirectoryWithoutIniYieldsNil() throws {
        let dir = try makeGameDir(inis: [:])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(GameINI.parseINIValue(at: dir, section: "game", key: "title"))
    }

    // MARK: - Encodings

    func testShiftJISTitleParses() throws {
        let title = "ポケットモンスター"
        guard let sjis = "[Game]\r\nTitle=\(title)\r\n".data(using: .shiftJIS) else {
            try skipOrFail("Shift-JIS encoding is unavailable on this platform")
        }
        // The fixture must not be valid UTF-8. Otherwise this would
        // not pin the Shift-JIS leg of decodeAsLooseText.
        XCTAssertNil(String(data: sjis, encoding: .utf8))

        let dir = try makeGameDir(inis: [:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let iniURL = dir.appendingPathComponent("Game.ini")
        try sjis.write(to: iniURL)

        XCTAssertEqual(
            GameINI.parseINIValue(in: iniURL, section: "game", key: "title"),
            title)
        XCTAssertEqual(
            GameINI.parseINIValue(at: dir, section: "game", key: "title"),
            title)
    }

    func testGameTitleReadsTheGameSectionTitle() throws {
        let dir = try makeGameDir(inis: [
            "Game.ini": "[Game]\r\nTitle=Pokémon Empyrean\r\n"
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(GameINI.gameTitle(at: dir), "Pokémon Empyrean")
    }

    func testSubdirectoryNamesListsDirectoriesOnly() throws {
        let fm = FileManager.default
        let dir = try makeGameDir(inis: ["stray.ini": ""])
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(
            at: dir.appendingPathComponent("Child"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        XCTAssertEqual(
            Set(fm.subdirectoryNames(at: dir)), Set(["Child", ".hidden"]))
        XCTAssertEqual(fm.subdirectoryNames(at: dir.appendingPathComponent("absent")), [])
    }
}

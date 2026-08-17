import Foundation
import XCTest

@testable import GameProbe

final class GameFolderNameTests: XCTestCase {

    // MARK: - sanitize

    func testPlainTitlePassesThrough() {
        XCTAssertEqual(GameFolderName.sanitize("Pokémon Uranium"), "Pokémon Uranium")
    }

    func testDisallowedCharactersBecomeSpaces() {
        XCTAssertEqual(GameFolderName.sanitize("Fate/Another"), "Fate Another")
        XCTAssertEqual(GameFolderName.sanitize("Re:Zero"), "Re Zero")
        XCTAssertEqual(GameFolderName.sanitize("A\\B*C?D\"E<F>G|H"), "A B C D E F G H")
    }

    func testWhitespaceRunsCollapse() {
        XCTAssertEqual(GameFolderName.sanitize("  Pokémon   Z  "), "Pokémon Z")
        XCTAssertEqual(GameFolderName.sanitize("A\tB"), "A B")
    }

    func testControlCharactersAndNewlinesBecomeSpaces() {
        XCTAssertEqual(GameFolderName.sanitize("Game\nTitle"), "Game Title")
        XCTAssertEqual(GameFolderName.sanitize("Game\u{01}Title"), "Game Title")
    }

    func testLeadingDotsStripped() {
        XCTAssertEqual(GameFolderName.sanitize(".hack"), "hack")
        XCTAssertEqual(GameFolderName.sanitize("..hidden"), "hidden")
    }

    func testTrailingDotsAndSpacesStripped() {
        XCTAssertEqual(GameFolderName.sanitize("Game Title..."), "Game Title")
    }

    func testInteriorDotsSurvive() {
        XCTAssertEqual(GameFolderName.sanitize("Ver 1.5"), "Ver 1.5")
    }

    func testEmptyAndDegenerateTitlesFallBack() {
        XCTAssertEqual(GameFolderName.sanitize(""), GameFolderName.fallback)
        XCTAssertEqual(GameFolderName.sanitize("   "), GameFolderName.fallback)
        XCTAssertEqual(GameFolderName.sanitize("..."), GameFolderName.fallback)
        XCTAssertEqual(GameFolderName.sanitize("///"), GameFolderName.fallback)
        XCTAssertEqual(GameFolderName.sanitize("."), GameFolderName.fallback)
    }

    func testLongTitleCappedFromTheFront() {
        // Distinct head/tail so keeping the wrong end (suffix
        // instead of prefix) fails, not only a wrong length.
        let long = "HEAD " + String(repeating: "a", count: 300) + " TAIL"
        let sanitized = GameFolderName.sanitize(long)
        XCTAssertEqual(sanitized.count, GameFolderName.maxLength)
        XCTAssertEqual(
            sanitized,
            "HEAD " + String(repeating: "a", count: GameFolderName.maxLength - 5))
    }

    func testLeadingDotWithSpaceStripped() {
        XCTAssertEqual(GameFolderName.sanitize(". hack"), "hack")
    }

    func testCapThenStripRemovesADotTheCapExposed() {
        // prefix(60) ends exactly on the dot, and the trailing-dot
        // strip must then run on the capped string.
        let title = String(repeating: "a", count: 59) + "." + String(repeating: "b", count: 30)
        XCTAssertEqual(GameFolderName.sanitize(title), String(repeating: "a", count: 59))
    }

    // MARK: - Windows reserved stems

    func testWindowsReservedStemsGetAnUnderscore() {
        XCTAssertEqual(GameFolderName.sanitize("NUL"), "NUL_")
        // The match ignores case. The original case stays.
        XCTAssertEqual(GameFolderName.sanitize("con"), "con_")
        XCTAssertEqual(GameFolderName.sanitize("COM3.txt"), "COM3_.txt")
        // The stem split takes only the FIRST dot segment.
        XCTAssertEqual(GameFolderName.sanitize("NUL.txt.rxdata"), "NUL_.txt.rxdata")
    }

    func testNonReservedStemStaysUntouched() {
        XCTAssertEqual(GameFolderName.sanitize("CONSOLE"), "CONSOLE")
    }

    func testEveryReservedStemFamilyGetsAnUnderscore() {
        XCTAssertEqual(GameFolderName.sanitize("PRN"), "PRN_")
        XCTAssertEqual(GameFolderName.sanitize("AUX"), "AUX_")
        XCTAssertEqual(GameFolderName.sanitize("LPT9"), "LPT9_")
        XCTAssertEqual(GameFolderName.sanitize("com1"), "com1_")
        // The superscript-digit variants Windows also reserves.
        XCTAssertEqual(GameFolderName.sanitize("COM¹"), "COM¹_")
    }

    func testFrontCleanupExposesAReservedStem() {
        // Stripping the leading dot (and then a space) uncovers the
        // reserved stem, so the escape must run AFTER the front
        // cleanup finishes.
        XCTAssertEqual(GameFolderName.sanitize(".NUL"), "NUL_")
        XCTAssertEqual(GameFolderName.sanitize(". NUL"), "NUL_")
    }

    func testEscapeRunsBeforeTheLengthCap() {
        // "NUL." + 56 a's is 60 chars. The escape makes it 61, and
        // prefix(60) then trims one trailing "a". Escaping after the
        // cap would instead produce a 61-char result and break both
        // the cap and idempotence.
        let title = "NUL." + String(repeating: "a", count: 56)
        let sanitized = GameFolderName.sanitize(title)
        XCTAssertEqual(sanitized, "NUL_." + String(repeating: "a", count: 55))
        XCTAssertEqual(sanitized.count, GameFolderName.maxLength)
    }

    // MARK: - Byte cap

    func testByteCapTrimsFourByteEmoji() {
        // 70 emoji pass the 60-char cap at 60. 60 x 4 = 240 bytes,
        // so the byte cap trims down to 45 (180 / 4).
        let title = String(repeating: "🎮", count: 70)
        let sanitized = GameFolderName.sanitize(title)
        XCTAssertEqual(sanitized, String(repeating: "🎮", count: 45))
        XCTAssertEqual(sanitized.utf8.count, 180)
    }

    func testByteCapTrimsOnGraphemeBoundaries() {
        // A skin-tone cluster is 8 UTF-8 bytes and contains no
        // format characters, so it survives the character
        // replacement intact. 22 clusters are 176 bytes. A 23rd
        // would break the 180-byte cap. The trim must remove whole
        // clusters, never half of one.
        let cluster = "👍🏽"
        XCTAssertEqual(cluster.utf8.count, 8)
        let sanitized = GameFolderName.sanitize(String(repeating: cluster, count: 30))
        XCTAssertEqual(sanitized, String(repeating: cluster, count: 22))
        XCTAssertLessThanOrEqual(sanitized.utf8.count, GameFolderName.maxUTF8Bytes)
    }

    func testZWJSequencesSplitIntoSpacedEmoji() {
        // CharacterSet.controlCharacters covers Unicode categories
        // Cc AND Cf. The zero-width joiner is Cf, so a family
        // cluster splits into its parts with spaces between them.
        // This pins the current behavior on purpose.
        XCTAssertEqual(GameFolderName.sanitize("👨‍👩‍👧‍👦"), "👨 👩 👧 👦")
    }

    func testSanitizeIsIdempotent() {
        let inputs = [
            "Pokémon Uranium",
            "Fate/Another",
            "  Pokémon   Z  ",
            ".hack//G.U.",
            String(repeating: "b c", count: 100),
            "...",
            "NUL",
            "con",
            "COM3.txt",
            "NUL.txt.rxdata",
            "CONSOLE",
            ". hack",
            ".NUL",
            ". NUL",
            "PRN",
            "AUX",
            "LPT9",
            "COM1",
            "COM¹",
            "com¹.txt",
            String(repeating: "🎮", count: 70),
            String(repeating: "👨‍👩‍👧‍👦", count: 25),
            String(repeating: "a", count: 59) + "." + String(repeating: "b", count: 30),
            // Reserved stems pushed across the char and byte caps.
            "NUL." + String(repeating: "a", count: 56),
            "NUL." + String(repeating: "🎮", count: 70),
            "NUL." + String(repeating: "👍🏽", count: 30),
        ]
        for input in inputs {
            let once = GameFolderName.sanitize(input)
            XCTAssertEqual(GameFolderName.sanitize(once), once, "not idempotent for \(input)")
            XCTAssertLessThanOrEqual(once.utf8.count, GameFolderName.maxUTF8Bytes)
        }
    }

    // MARK: - uniqueName

    func testUniqueNamePrefersUnsuffixedName() {
        let name = GameFolderName.uniqueName(preferring: "Pokemon Z") { _ in false }
        XCTAssertEqual(name, "Pokemon Z")
    }

    func testUniqueNameAppendsNumberedSuffix() {
        var taken: Set<String> = ["pokemon z", "pokemon z 2"]
        let name = GameFolderName.uniqueName(preferring: "Pokemon Z") {
            taken.contains($0.lowercased())
        }
        XCTAssertEqual(name, "Pokemon Z 3")
        taken.insert(name.lowercased())
        let next = GameFolderName.uniqueName(preferring: "Pokemon Z") {
            taken.contains($0.lowercased())
        }
        XCTAssertEqual(next, "Pokemon Z 4")
    }

    func testUniqueNameFirstSuffixIsSpaceTwo() {
        let name = GameFolderName.uniqueName(preferring: "Save") { $0 == "Save" }
        XCTAssertEqual(name, "Save 2")
    }

    func testUniqueNameStacksSuffixOnAlreadySuffixedName() {
        let name = GameFolderName.uniqueName(preferring: "Save 2") { $0 == "Save 2" }
        XCTAssertEqual(name, "Save 2 2")
    }

    func testUniqueNameTerminatesWhenEverySuffixTaken() {
        let name = GameFolderName.uniqueName(preferring: "Game") { candidate in
            !candidate.contains("-")  // free only once the UUID fallback appears
        }
        XCTAssertTrue(name.hasPrefix("Game "))
        XCTAssertTrue(name.contains("-"))
    }

    func testUniqueNameProbes999CandidatesThenFallsBackToUUID() {
        // The preferred name is probe 1. "Game 2"..."Game 999" are
        // probes 2...999. The UUID fallback returns without another
        // probe.
        var probes = 0
        let name = GameFolderName.uniqueName(preferring: "Game") { _ in
            probes += 1
            return true
        }
        XCTAssertEqual(probes, 999)
        XCTAssertTrue(name.hasPrefix("Game "))
        XCTAssertNotNil(UUID(uuidString: String(name.dropFirst("Game ".count))))
    }
}

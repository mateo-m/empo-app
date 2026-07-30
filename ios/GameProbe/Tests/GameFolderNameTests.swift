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
        // instead of prefix) fails, not just a wrong length.
        let long = "HEAD " + String(repeating: "a", count: 300) + " TAIL"
        let sanitized = GameFolderName.sanitize(long)
        XCTAssertEqual(sanitized.count, GameFolderName.maxLength)
        XCTAssertEqual(
            sanitized,
            "HEAD " + String(repeating: "a", count: GameFolderName.maxLength - 5))
    }

    func testSanitizeIsIdempotent() {
        let inputs = [
            "Pokémon Uranium",
            "Fate/Another",
            "  Pokémon   Z  ",
            ".hack//G.U.",
            String(repeating: "b c", count: 100),
            "...",
        ]
        for input in inputs {
            let once = GameFolderName.sanitize(input)
            XCTAssertEqual(GameFolderName.sanitize(once), once, "not idempotent for \(input)")
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

    func testUniqueNameTerminatesWhenEverySuffixTaken() {
        let name = GameFolderName.uniqueName(preferring: "Game") { candidate in
            !candidate.contains("-")  // free only once the UUID fallback appears
        }
        XCTAssertTrue(name.hasPrefix("Game "))
        XCTAssertTrue(name.contains("-"))
    }
}

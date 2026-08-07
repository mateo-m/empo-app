import Foundation
import XCTest

@testable import GameProbe

final class DirectoryNameMatchTests: XCTestCase {

    func testExactMatchWinsOverCaseVariants() {
        XCTAssertEqual(
            DirectoryNameMatch.preferringExisting("reborn", among: ["Reborn", "reborn"]),
            "reborn")
    }

    func testFirstCaseInsensitiveMatchInSortedOrder() {
        // "REBORN" < "reborn" in String sort, so the uppercase
        // variant wins deterministically.
        XCTAssertEqual(
            DirectoryNameMatch.preferringExisting("Reborn", among: ["reborn", "REBORN"]),
            "REBORN")
        XCTAssertEqual(
            DirectoryNameMatch.preferringExisting("Reborn", among: ["REBORN", "reborn"]),
            "REBORN")
    }

    func testNoMatchReturnsInputUnchanged() {
        XCTAssertEqual(
            DirectoryNameMatch.preferringExisting("Uranium", among: ["Reborn", "Rejuvenation"]),
            "Uranium")
    }

    func testEmptyListReturnsInput() {
        XCTAssertEqual(DirectoryNameMatch.preferringExisting("Reborn", among: []), "Reborn")
    }

    func testLegacyMojibakeDirectoryIsReused() throws {
        guard DirectoryNameMatch.legacyMojibakeRendering(of: "Pokémon Empyrean") != nil else {
            throw XCTSkip("Legacy encodings are unavailable on this platform")
        }
        // An install from the Shift-JIS-first decode era stored
        // saves under the mojibake name. The corrected title must
        // keep resolving to that directory.
        XCTAssertEqual(
            DirectoryNameMatch.preferringExisting(
                "Pokémon Empyrean", among: ["Pok駑on Empyrean", "Reborn"]),
            "Pok駑on Empyrean")
    }

    func testCorrectDirectoryWinsOverMojibakeVariant() {
        XCTAssertEqual(
            DirectoryNameMatch.preferringExisting(
                "Pokémon Empyrean", among: ["Pok駑on Empyrean", "Pokémon Empyrean"]),
            "Pokémon Empyrean")
    }

    func testASCIINamesHaveNoMojibakeRendering() {
        XCTAssertNil(DirectoryNameMatch.legacyMojibakeRendering(of: "Reborn"))
    }
}

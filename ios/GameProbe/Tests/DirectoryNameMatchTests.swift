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
}

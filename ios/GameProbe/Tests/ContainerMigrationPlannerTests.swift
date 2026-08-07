import Foundation
import XCTest

@testable import GameProbe

final class ContainerMigrationPlannerTests: XCTestCase {

    private let uuidA = "AAAAAAAA-1111-2222-3333-444444444444"
    private let uuidB = "BBBBBBBB-1111-2222-3333-444444444444"

    private func candidate(
        id: String,
        name: String,
        played: TimeInterval? = nil,
        added: TimeInterval? = nil
    ) -> ContainerMigrationPlanner.Candidate {
        ContainerMigrationPlanner.Candidate(
            id: id,
            preferredName: name,
            lastPlayed: played.map { Date(timeIntervalSince1970: $0) },
            dateAdded: added.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: - plan

    func testSingleCandidateFormsItsOwnUnclaimedGroup() {
        let groups = ContainerMigrationPlanner.plan(
            candidates: [candidate(id: "a", name: "Testing")],
            takenLowercasedNames: []
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].candidates.map(\.id), ["a"])
        XCTAssertFalse(groups[0].titleAlreadyTaken)
    }

    func testMostRecentlyPlayedIsCanonical() {
        let groups = ContainerMigrationPlanner.plan(
            candidates: [
                candidate(id: "older", name: "Testing", played: 100),
                candidate(id: "newer", name: "Testing", played: 200),
            ],
            takenLowercasedNames: []
        )
        XCTAssertEqual(groups[0].candidates.map(\.id), ["newer", "older"])
    }

    func testPlayedBeatsNeverPlayed() {
        let groups = ContainerMigrationPlanner.plan(
            candidates: [
                candidate(id: "unplayed", name: "Testing", added: 999),
                candidate(id: "played", name: "Testing", played: 1),
            ],
            takenLowercasedNames: []
        )
        XCTAssertEqual(groups[0].candidates.first?.id, "played")
    }

    func testDateAddedBreaksPlayedTies() {
        let groups = ContainerMigrationPlanner.plan(
            candidates: [
                candidate(id: "old-install", name: "Testing", played: 100, added: 10),
                candidate(id: "new-install", name: "Testing", played: 100, added: 20),
            ],
            takenLowercasedNames: []
        )
        XCTAssertEqual(groups[0].candidates.first?.id, "new-install")
    }

    func testIDBreaksFullTiesDeterministically() {
        let groups = ContainerMigrationPlanner.plan(
            candidates: [
                candidate(id: "b", name: "Testing"),
                candidate(id: "a", name: "Testing"),
            ],
            takenLowercasedNames: []
        )
        XCTAssertEqual(groups[0].candidates.map(\.id), ["a", "b"])
    }

    func testGroupingIsCaseInsensitive() {
        let groups = ContainerMigrationPlanner.plan(
            candidates: [
                candidate(id: "a", name: "TESTING", played: 200),
                candidate(id: "b", name: "Testing", played: 100),
            ],
            takenLowercasedNames: []
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].candidates.map(\.id), ["a", "b"])
    }

    func testTakenTitleMarksWholeGroup() {
        let groups = ContainerMigrationPlanner.plan(
            candidates: [candidate(id: "a", name: "Testing")],
            takenLowercasedNames: ["testing"]
        )
        XCTAssertTrue(groups[0].titleAlreadyTaken)
    }

    func testDatedBeatsUndatedAmongNeverPlayed() {
        // Neither candidate was played; the one with a real
        // dateAdded must rank above the one with none.
        let groups = ContainerMigrationPlanner.plan(
            candidates: [
                candidate(id: "undated", name: "Testing"),
                candidate(id: "dated", name: "Testing", added: 10),
            ],
            takenLowercasedNames: []
        )
        XCTAssertEqual(groups[0].candidates.map(\.id), ["dated", "undated"])
    }

    func testThreeWayOrderingAcrossTiers() {
        // Tier order: last played, then date added, then id. The
        // ids sort AGAINST the expected order, so an id-only sort
        // fails this test.
        let groups = ContainerMigrationPlanner.plan(
            candidates: [
                candidate(id: "a-nothing", name: "Testing"),
                candidate(id: "b-added", name: "Testing", added: 100),
                candidate(id: "c-played", name: "Testing", played: 50),
            ],
            takenLowercasedNames: []
        )
        XCTAssertEqual(
            groups[0].candidates.map(\.id),
            ["c-played", "b-added", "a-nothing"])
    }

    func testEmptyCandidatesYieldNoGroups() {
        XCTAssertEqual(
            ContainerMigrationPlanner.plan(candidates: [], takenLowercasedNames: ["testing"]),
            [])
    }

    func testDistinctTitlesStayIndependentAndSorted() {
        let groups = ContainerMigrationPlanner.plan(
            candidates: [
                candidate(id: "z", name: "Zelda-like"),
                candidate(id: "a", name: "Adventure"),
            ],
            takenLowercasedNames: ["zelda-like"]
        )
        XCTAssertEqual(groups.map { $0.candidates[0].id }, ["a", "z"])
        XCTAssertFalse(groups[0].titleAlreadyTaken)
        XCTAssertTrue(groups[1].titleAlreadyTaken)
    }

    // MARK: - legacyUUIDPrefix

    func testLegacyPrefixParsesUUIDSlugNames() {
        XCTAssertEqual(
            ContainerMigrationPlanner.legacyUUIDPrefix(folderName: "\(uuidA)-pokemon-uranium"),
            uuidA)
        XCTAssertEqual(
            ContainerMigrationPlanner.legacyUUIDPrefix(folderName: uuidB),
            uuidB)
    }

    func testLegacyPrefixRejectsTitleBasedNames() {
        XCTAssertNil(ContainerMigrationPlanner.legacyUUIDPrefix(folderName: "Pokémon Uranium"))
        XCTAssertNil(ContainerMigrationPlanner.legacyUUIDPrefix(folderName: "short"))
        XCTAssertNil(
            ContainerMigrationPlanner.legacyUUIDPrefix(
                folderName: "not-a-uuid-prefix-that-is-36-chars-x-rest"))
    }

    func testLegacyPrefixRejectsUUIDFollowedByNonDash() {
        // A migrated title that merely STARTS with a UUID is not a
        // legacy name.
        XCTAssertNil(
            ContainerMigrationPlanner.legacyUUIDPrefix(folderName: "\(uuidA)xgarbage"))
    }

    func testLegacyPrefixAcceptsBothLetterCases() {
        XCTAssertEqual(
            ContainerMigrationPlanner.legacyUUIDPrefix(folderName: uuidA.lowercased()),
            uuidA.lowercased())
        XCTAssertEqual(
            ContainerMigrationPlanner.legacyUUIDPrefix(folderName: uuidA.uppercased()),
            uuidA.uppercased())
    }

    func testLegacyPrefixAcceptsEmptySlug() {
        XCTAssertEqual(
            ContainerMigrationPlanner.legacyUUIDPrefix(folderName: "\(uuidA)-"),
            uuidA)
    }

    // MARK: - slugTitle

    func testSlugTitleDeslugs() {
        XCTAssertEqual(
            ContainerMigrationPlanner.slugTitle(
                fromLegacyFolderName: "\(uuidA)-pokemon-uranium"),
            "pokemon uranium")
    }

    func testSlugTitleNilWithoutSlug() {
        XCTAssertNil(ContainerMigrationPlanner.slugTitle(fromLegacyFolderName: uuidA))
        XCTAssertNil(ContainerMigrationPlanner.slugTitle(fromLegacyFolderName: "\(uuidA)-"))
        XCTAssertNil(ContainerMigrationPlanner.slugTitle(fromLegacyFolderName: "Pokémon Uranium"))
    }

    func testSlugTitleCollapsesConsecutiveDashes() {
        XCTAssertEqual(
            ContainerMigrationPlanner.slugTitle(
                fromLegacyFolderName: "\(uuidA)-pokemon--uranium"),
            "pokemon uranium")
    }

    func testSlugTitleAcceptsSingleCharacterSlug() {
        XCTAssertEqual(
            ContainerMigrationPlanner.slugTitle(fromLegacyFolderName: "\(uuidA)-x"),
            "x")
    }

    // MARK: - Mojibake rename targets

    func testMojibakeFolderRenamesToCorrectedTitle() throws {
        guard DirectoryNameMatch.legacyMojibakeRendering(of: "Pokémon Empyrean") != nil else {
            throw XCTSkip("Legacy encodings are unavailable on this platform")
        }
        XCTAssertEqual(
            ContainerMigrationPlanner.mojibakeRenameTarget(
                folderName: "Pok駑on Empyrean", title: "Pokémon Empyrean"),
            "Pokémon Empyrean")
    }

    func testCorrectlyNamedFolderIsNotARenameCandidate() {
        XCTAssertNil(
            ContainerMigrationPlanner.mojibakeRenameTarget(
                folderName: "Pokémon Empyrean", title: "Pokémon Empyrean"))
        XCTAssertNil(
            ContainerMigrationPlanner.mojibakeRenameTarget(
                folderName: "Pokemon Uranium", title: "Pokemon Uranium"))
    }

    func testJapaneseFolderIsNotARenameCandidate() {
        // A genuine Japanese title has no Windows-1252 rendering,
        // so it must never be treated as mojibake.
        XCTAssertNil(
            ContainerMigrationPlanner.mojibakeRenameTarget(
                folderName: "ポケットモンスター", title: "ポケットモンスター"))
    }

    func testUnrelatedNameIsNotARenameCandidate() {
        // The folder differs from the title, but not in the way the
        // old decoder produced - a rename here would be a guess.
        XCTAssertNil(
            ContainerMigrationPlanner.mojibakeRenameTarget(
                folderName: "Pok mon Empyrean", title: "Pokémon Empyrean"))
    }

    func testRenameTargetSanitizesTheTitle() throws {
        guard DirectoryNameMatch.legacyMojibakeRendering(of: "Pokémon Empyrean") != nil else {
            throw XCTSkip("Legacy encodings are unavailable on this platform")
        }
        // Sanitization replaces ":" before the mojibake comparison,
        // matching how the import named the folder in the first
        // place.
        XCTAssertEqual(
            ContainerMigrationPlanner.mojibakeRenameTarget(
                folderName: "Pok駑on Empyrean", title: "Pokémon: Empyrean"),
            "Pokémon Empyrean")
    }
}

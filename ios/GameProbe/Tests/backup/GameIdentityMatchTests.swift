import Foundation
import XCTest

@testable import GameProbe

/// The match ladder of SPEC 4.2 and the attach of 4.3.
final class GameIdentityMatchTests: XCTestCase {

    private func snapshot(_ name: String, alias: String? = nil) -> SnapshotIdentity {
        SnapshotIdentity(containerFolderName: name, identityAlias: alias)
    }

    // MARK: - The four rungs, per 4.2

    func testExactNameMatches() {
        let game = GameIdentity(folderName: "Fixture Quest")

        XCTAssertTrue(GameIdentityMatch.matches(snapshot("Fixture Quest"), game))
        XCTAssertEqual(GameIdentityMatch.match(snapshot("Fixture Quest"), among: [game]), game)
    }

    func testCaseDifferenceMatches() {
        let game = GameIdentity(folderName: "Fixture Quest")

        XCTAssertTrue(GameIdentityMatch.matches(snapshot("fixture quest"), game))
        XCTAssertEqual(GameIdentityMatch.match(snapshot("FIXTURE QUEST"), among: [game]), game)
    }

    func testMojibakeRenderingMatches() throws {
        let corrected = "Pokémon Uranium"
        guard let mojibake = DirectoryNameMatch.legacyMojibakeRendering(of: corrected) else {
            try skipOrFail("Legacy encodings are unavailable on this platform")
        }
        XCTAssertNotEqual(mojibake, corrected)

        // The snapshot came from a device of the old decode chain,
        // so it carries the mojibake name. The corrected name must
        // still find it.
        let game = GameIdentity(folderName: corrected)
        XCTAssertTrue(GameIdentityMatch.matches(snapshot(mojibake), game))
        XCTAssertEqual(GameIdentityMatch.match(snapshot(mojibake), among: [game]), game)
    }

    func testInvisibleCharacterVariantMatches() {
        // A title that carried a variation selector made a directory
        // with the selector in its name. The sanitizer drops it now.
        let withSelector = "Fixture Quest\u{FE0F}"
        let game = GameIdentity(folderName: "Fixture Quest")

        XCTAssertTrue(GameIdentityMatch.matches(snapshot(withSelector), game))
        XCTAssertEqual(GameIdentityMatch.match(snapshot(withSelector), among: [game]), game)
    }

    func testUnrelatedNameDoesNotMatch() {
        let game = GameIdentity(folderName: "Fixture Quest")

        XCTAssertFalse(GameIdentityMatch.matches(snapshot("Long Gone"), game))
        XCTAssertNil(GameIdentityMatch.match(snapshot("Long Gone"), among: [game]))
    }

    // MARK: - The ladder renames nothing, per 4.2

    func testMatchingRenamesNothing() {
        let game = GameIdentity(folderName: "fixture quest")
        let stored = snapshot("Fixture Quest")

        let matched = GameIdentityMatch.match(stored, among: [game])

        XCTAssertEqual(matched?.folderName, "fixture quest")
        XCTAssertEqual(stored.containerFolderName, "Fixture Quest")
    }

    func testGameKeyStaysTheHashOfTheStoredNameAfterACaseMatch() {
        let game = GameIdentity(folderName: "fixture quest")
        let stored = snapshot("Fixture Quest")

        XCTAssertTrue(GameIdentityMatch.matches(stored, game))
        XCTAssertEqual(stored.gameKey, ContentHash.hex(ofUTF8: "Fixture Quest"))
        XCTAssertEqual(game.gameKey, ContentHash.hex(ofUTF8: "fixture quest"))
        XCTAssertNotEqual(stored.gameKey, game.gameKey)
    }

    // MARK: - Cross-device, per 4.2

    func testTwoDevicesThatImportedTheSameGameMatch() {
        // Two independent imports of one game make one folder name,
        // because the name is the sanitized INI title.
        let here = GameIdentity(folderName: GameFolderName.sanitize("Fixture Quest"))
        let there = snapshot(GameFolderName.sanitize("Fixture Quest"))

        XCTAssertEqual(GameIdentityMatch.match(there, among: [here]), here)
    }

    // MARK: - Aliases, per 4.3

    func testAnAliasMatches() {
        let game = GameIdentity(folderName: "Fixture Quest 2", aliases: ["Fixture Quest"])

        XCTAssertTrue(GameIdentityMatch.matches(snapshot("Fixture Quest"), game))
        XCTAssertEqual(GameIdentityMatch.match(snapshot("Fixture Quest"), among: [game]), game)
    }

    func testTwoAliasesOnOneGameBothMatch() {
        let game = GameIdentity(
            folderName: "Fixture Quest 3",
            aliases: ["Fixture Quest", "Fixture Quest 2"])

        XCTAssertEqual(GameIdentityMatch.match(snapshot("Fixture Quest"), among: [game]), game)
        XCTAssertEqual(GameIdentityMatch.match(snapshot("Fixture Quest 2"), among: [game]), game)
        XCTAssertEqual(GameIdentityMatch.match(snapshot("Fixture Quest 3"), among: [game]), game)
    }

    func testAManifestAliasMatchesADeviceWithNoLocalState() {
        // The fresh-install case of 4.3: the device has the old name
        // and reads the alias out of the manifest header.
        let manifest = SnapshotManifest(
            mode: .slim,
            containerFolderName: "Fixture Quest 2",
            identityAlias: "Fixture Quest")
        let game = GameIdentity(folderName: "Fixture Quest")

        XCTAssertTrue(GameIdentityMatch.matches(SnapshotIdentity(manifest: manifest), game))
    }

    func testTheExactNameWinsOverALadderMatch() {
        let exact = GameIdentity(folderName: "Fixture Quest")
        let alias = GameIdentity(folderName: "Another Game", aliases: ["fixture quest"])

        XCTAssertEqual(
            GameIdentityMatch.match(snapshot("Fixture Quest"), among: [alias, exact]),
            exact)
    }

    // MARK: - The attach, per 4.3

    func testAnAttachNamesTheOldFolderName() {
        let game = GameIdentity(folderName: "Fixture Quest 2")

        XCTAssertEqual(
            GameIdentityMatch.alias(attaching: snapshot("Fixture Quest"), to: game),
            "Fixture Quest")
    }

    func testAnAttachOfAMatchingSnapshotRecordsNothing() {
        let game = GameIdentity(folderName: "Fixture Quest 2", aliases: ["Fixture Quest"])

        XCTAssertNil(GameIdentityMatch.alias(attaching: snapshot("Fixture Quest"), to: game))
    }
}

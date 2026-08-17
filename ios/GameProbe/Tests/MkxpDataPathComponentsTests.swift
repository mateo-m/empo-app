import Foundation
import XCTest

@testable import GameProbe

final class MkxpDataPathComponentsTests: XCTestCase {

    func testUndeclaredPathFallsBackToINITitle() {
        // Desktop mkxp-z resolves a pref path for every game. Keys
        // absent means org "." (nothing) and app = INI title.
        XCTAssertEqual(
            MkxpDataPath().sharedDirectoryComponents(iniTitleFallback: "Testing"),
            ["Testing"])
    }

    func testUndeclaredPathAndNoTitleFallBackToEngineDefault() {
        XCTAssertEqual(
            MkxpDataPath().sharedDirectoryComponents(iniTitleFallback: nil),
            ["mkxp-z"])
    }

    func testOrgAndAppBothContribute() {
        let dataPath = MkxpDataPath(org: "fangame-dev", app: "reborn")
        XCTAssertEqual(
            dataPath.sharedDirectoryComponents(iniTitleFallback: nil),
            ["fangame-dev", "reborn"])
    }

    func testAbsentOrgContributesNothing() {
        let dataPath = MkxpDataPath(app: "reborn")
        XCTAssertEqual(dataPath.sharedDirectoryComponents(iniTitleFallback: nil), ["reborn"])
    }

    func testDegenerateValuesContributeNothing() {
        // Values that sanitize down to nothing ("...", "///") must
        // not become a literal "Unknown Game" path component. They
        // fall out of the chain like absent values.
        let dotsOrg = MkxpDataPath(org: "...", app: "reborn")
        XCTAssertEqual(dotsOrg.sharedDirectoryComponents(iniTitleFallback: nil), ["reborn"])

        let slashesApp = MkxpDataPath(org: "dev", app: "///")
        XCTAssertEqual(
            slashesApp.sharedDirectoryComponents(iniTitleFallback: "Testing"),
            ["dev", "Testing"])
        XCTAssertEqual(
            slashesApp.sharedDirectoryComponents(iniTitleFallback: nil),
            ["dev", "mkxp-z"])
    }

    func testDotOrgContributesNothing() {
        let dataPath = MkxpDataPath(org: ".", app: "reborn")
        XCTAssertEqual(dataPath.sharedDirectoryComponents(iniTitleFallback: nil), ["reborn"])
    }

    func testBlankOrgContributesNothing() {
        let dataPath = MkxpDataPath(org: "   ", app: "reborn")
        XCTAssertEqual(dataPath.sharedDirectoryComponents(iniTitleFallback: nil), ["reborn"])
    }

    func testMissingAppFallsBackToINITitle() {
        let dataPath = MkxpDataPath(org: "dev")
        XCTAssertEqual(
            dataPath.sharedDirectoryComponents(iniTitleFallback: "Pokémon Uranium"),
            ["dev", "Pokémon Uranium"])
    }

    func testMissingAppAndTitleFallBackToEngineDefault() {
        let dataPath = MkxpDataPath(org: "dev")
        XCTAssertEqual(
            dataPath.sharedDirectoryComponents(iniTitleFallback: nil),
            ["dev", "mkxp-z"])
        XCTAssertEqual(
            dataPath.sharedDirectoryComponents(iniTitleFallback: "   "),
            ["dev", "mkxp-z"])
    }

    func testDotAppFallsBackLikeMissingApp() {
        let dataPath = MkxpDataPath(org: "dev", app: ".")
        XCTAssertEqual(
            dataPath.sharedDirectoryComponents(iniTitleFallback: "Testing"),
            ["dev", "Testing"])
    }

    func testComponentsAreSanitizedToSinglePathComponents() {
        let dataPath = MkxpDataPath(org: "dev/team", app: "game:v2")
        XCTAssertEqual(
            dataPath.sharedDirectoryComponents(iniTitleFallback: nil),
            ["dev team", "game v2"])
    }

    // MARK: - Fallback chain: app -> INI title -> folder name -> "mkxp-z"

    func testDeclaredAppBeatsINITitle() {
        XCTAssertEqual(
            MkxpDataPath(app: "reborn")
                .sharedDirectoryComponents(iniTitleFallback: "Pokemon Reborn"),
            ["reborn"])
    }

    func testINITitleBeatsFolderName() {
        XCTAssertEqual(
            MkxpDataPath().sharedDirectoryComponents(
                iniTitleFallback: "Testing",
                folderNameFallback: "My Game Folder"),
            ["Testing"])
    }

    func testFolderNameUsedWhenAppAndTitleAbsent() {
        XCTAssertEqual(
            MkxpDataPath().sharedDirectoryComponents(
                iniTitleFallback: nil,
                folderNameFallback: "My Game Folder"),
            ["My Game Folder"])
    }

    func testAllThreeAbsentFallBackToEngineDefault() {
        XCTAssertEqual(
            MkxpDataPath().sharedDirectoryComponents(
                iniTitleFallback: nil,
                folderNameFallback: nil),
            ["mkxp-z"])
    }

    func testLiteralUnknownGameAppContributes() {
        // The sanitizer's fallback name is only suppressed for
        // values that sanitize DOWN to it. A game that literally
        // declares "Unknown Game" keeps its declared directory.
        XCTAssertEqual(
            MkxpDataPath(app: "Unknown Game")
                .sharedDirectoryComponents(iniTitleFallback: "Real Title"),
            ["Unknown Game"])
    }

    func testCaseVariantUnknownGameAppContributes() {
        // The suppression targets values that SANITIZE to the exact
        // fallback literal. "UNKNOWN GAME" sanitizes to itself, which
        // differs from "Unknown Game", so it contributes.
        XCTAssertEqual(
            MkxpDataPath(app: "UNKNOWN GAME")
                .sharedDirectoryComponents(iniTitleFallback: "Real Title"),
            ["UNKNOWN GAME"])
    }

    func testLiteralUnknownGameOrgContributes() {
        // Same literal-vs-coincidence rule as the app component: a
        // declared org of exactly "Unknown Game" stays.
        XCTAssertEqual(
            MkxpDataPath(org: "Unknown Game", app: "reborn")
                .sharedDirectoryComponents(iniTitleFallback: nil),
            ["Unknown Game", "reborn"])
    }

    func testValidOrgAppAndTitleYieldOrgAndApp() {
        XCTAssertEqual(
            MkxpDataPath(org: "fangame-dev", app: "reborn")
                .sharedDirectoryComponents(iniTitleFallback: "Pokemon Reborn"),
            ["fangame-dev", "reborn"])
    }

    func testDegenerateOrgAloneFallsAllTheWayThrough() {
        XCTAssertEqual(
            MkxpDataPath(org: "...")
                .sharedDirectoryComponents(iniTitleFallback: nil, folderNameFallback: nil),
            ["mkxp-z"])
    }

    func testLongTitleFallbackIsCapped() {
        let long = "HEAD " + String(repeating: "a", count: 300)
        let components = MkxpDataPath().sharedDirectoryComponents(iniTitleFallback: long)
        XCTAssertEqual(components, [GameFolderName.sanitize(long)])
        XCTAssertEqual(components[0].count, GameFolderName.maxLength)
    }

    func testTitleThatSanitizesToTheFallbackNameContributesNothing() {
        // "Unknown  Game" (double space) sanitizes to "Unknown
        // Game", which equals the sanitizer's fallback, but the raw
        // trimmed value differs from it. Deliberate: only the exact
        // literal keeps the name. A coincidental collision falls
        // through the chain like a degenerate value.
        XCTAssertEqual(
            MkxpDataPath(app: "Unknown  Game").sharedDirectoryComponents(
                iniTitleFallback: nil,
                folderNameFallback: "Folder Name"),
            ["Folder Name"])
    }
}

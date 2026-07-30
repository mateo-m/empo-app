import Foundation
import XCTest

@testable import GameProbe

final class MkxpDataPathComponentsTests: XCTestCase {

    func testUndeclaredPathYieldsNoComponents() {
        XCTAssertNil(MkxpDataPath().sharedDirectoryComponents(iniTitleFallback: "Testing"))
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
        // not become a literal "Unknown Game" path component; they
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
}

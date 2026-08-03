import Foundation
import XCTest

@testable import GameProbe

final class LegacyDataPathDefaultsTests: XCTestCase {

    func testDeclaredValuesPassThroughUnsanitized() {
        // The legacy engine fed raw strings to SDL_GetPrefPath, so
        // the resolver must NOT sanitize them.
        let pair = LegacyDataPathDefaults.resolve(
            declaredOrg: "dev/team", declaredApp: "my:game", iniTitle: nil)
        XCTAssertEqual(pair.org, "dev/team")
        XCTAssertEqual(pair.app, "my:game")
    }

    func testMissingOrgBecomesDot() {
        XCTAssertEqual(
            LegacyDataPathDefaults.resolve(declaredOrg: nil, declaredApp: "app", iniTitle: nil).org,
            ".")
        XCTAssertEqual(
            LegacyDataPathDefaults.resolve(declaredOrg: "  ", declaredApp: "app", iniTitle: nil).org,
            ".")
    }

    func testMissingAppFallsBackToTitle() {
        XCTAssertEqual(
            LegacyDataPathDefaults.resolve(
                declaredOrg: nil, declaredApp: nil, iniTitle: "Pokemon Reborn").app,
            "Pokemon Reborn")
        XCTAssertEqual(
            LegacyDataPathDefaults.resolve(
                declaredOrg: nil, declaredApp: "   ", iniTitle: "Pokemon Reborn").app,
            "Pokemon Reborn")
    }

    func testMissingAppAndTitleFallBackToEngineDefault() {
        XCTAssertEqual(
            LegacyDataPathDefaults.resolve(declaredOrg: nil, declaredApp: nil, iniTitle: nil).app,
            "mkxp-z")
        XCTAssertEqual(
            LegacyDataPathDefaults.resolve(declaredOrg: nil, declaredApp: "", iniTitle: " ").app,
            "mkxp-z")
    }

    func testValuesAreWhitespaceTrimmed() {
        let pair = LegacyDataPathDefaults.resolve(
            declaredOrg: " dev ", declaredApp: nil, iniTitle: "\tTitle\n")
        XCTAssertEqual(pair.org, "dev")
        XCTAssertEqual(pair.app, "Title")
    }
}

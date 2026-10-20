import XCTest

@testable import GameProbe

final class ProfileSourceTests: XCTestCase {

    func testCases() {
        XCTAssertEqual(ProfileSource.name(pin: .profile("A"), defaultProfileName: "D"), "A")
        XCTAssertNil(ProfileSource.name(pin: .gameLayout, defaultProfileName: "D"))
        XCTAssertEqual(ProfileSource.name(pin: .defaultProfile, defaultProfileName: "D"), "D")
        XCTAssertEqual(ProfileSource.name(pin: .followChain, defaultProfileName: "D"), "D")
        XCTAssertNil(ProfileSource.name(pin: .defaultProfile, defaultProfileName: nil))
        XCTAssertNil(ProfileSource.name(pin: .followChain, defaultProfileName: nil))
    }
}

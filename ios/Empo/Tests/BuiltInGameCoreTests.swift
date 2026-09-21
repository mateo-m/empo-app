import XCTest

@testable import Empo

final class BuiltInGameCoreTests: XCTestCase {
    /// The screen names a core when the app can open it, and stays
    /// silent when it cannot.
    func testTheScreenNamesEveryCoreTheAppCanOpen() throws {
        let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)

        for framework in ["MkxpCore", "PsdkCore"] {
            let binary =
                frameworks
                .appendingPathComponent("\(framework).framework")
                .appendingPathComponent(framework)
            let inBundle = FileManager.default.fileExists(atPath: binary.path)
            let onScreen = BuiltInGameCore.all.contains { $0.id == framework }
            XCTAssertEqual(
                onScreen, inBundle,
                "\(framework): the screen says \(onScreen), the bundle says \(inBundle)")
        }
    }

    func testEveryCoreOnTheScreenCarriesAVersion() {
        XCTAssertFalse(BuiltInGameCore.all.isEmpty, "this build runs no game")
        for core in BuiltInGameCore.all {
            XCTAssertNotEqual(
                core.version, "unknown",
                "\(core.id).framework has no EmpoCoreVersion in its Info.plist")
        }
    }
}

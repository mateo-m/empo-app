import XCTest

@testable import GameProbe

final class SkinControlsVisibilityTests: XCTestCase {

    private func resolve(
        art: Bool, outlines: Bool = false, edit: Bool = false, hidden: Bool = false
    ) -> SkinControlsVisibility {
        SkinControlsVisibility.resolve(
            hasArt: art, showButtonOutlines: outlines, editMode: edit, controlsHidden: hidden)
    }

    func testArtOutlinesOff() {
        let v = resolve(art: true)
        XCTAssertTrue(v.mounted)
        XCTAssertFalse(v.drawn)
    }

    func testArtOutlinesOn() {
        let v = resolve(art: true, outlines: true)
        XCTAssertTrue(v.mounted)
        XCTAssertTrue(v.drawn)
    }

    func testArtEditMode() {
        let v = resolve(art: true, edit: true)
        XCTAssertTrue(v.mounted)
        XCTAssertTrue(v.drawn)
    }

    /// Eye toggle or a connected controller: no touches at all, so a
    /// hand resting on the screen cannot press anything.
    func testArtHidden() {
        XCTAssertFalse(resolve(art: true, hidden: true).mounted)
    }

    func testNoArtThisOrientationBehavesAsToday() {
        for hidden in [false, true] {
            let v = resolve(art: false, hidden: hidden)
            XCTAssertEqual(v.mounted, !hidden)
            XCTAssertTrue(v.drawn)
        }
    }
}

import XCTest

@testable import GameProbe

final class OverlayVisibilityTests: XCTestCase {

    func testOverlayStaysVisibleWithNoPhysicalInput() {
        XCTAssertEqual(OverlayVisibility().hidden, false)
    }

    func testExtendedControllerHidesTheOverlay() {
        var state = OverlayVisibility()
        state.setExtendedController(true, isFirstController: true)
        XCTAssertEqual(state.hidden, true)
    }

    func testAttachedKeyboardAloneKeepsTheOverlay() {
        // iOS reports one coalesced keyboard, so a connect says
        // nothing about whether the player is using a pad.
        XCTAssertEqual(OverlayVisibility().hidden, false)
    }

    func testFirstKeyPressHidesTheOverlay() {
        var state = OverlayVisibility()
        state.noteKeyPress()
        XCTAssertEqual(state.hidden, true)
    }

    func testManualToggleStopsTheRule() {
        var state = OverlayVisibility()
        state.noteManualToggle()
        state.noteKeyPress()
        XCTAssertNil(state.hidden)
    }

    func testControllerDisconnectDoesNotUnhideAfterKeyboardUse() {
        // The bug this rule exists for: a keyboard-mode pad hides the
        // overlay, then any pad disconnect used to show it again.
        var state = OverlayVisibility()
        state.setExtendedController(true, isFirstController: true)
        state.noteKeyPress()
        state.noteAllControllersDisconnected()
        XCTAssertEqual(state.hidden, true)
    }

    func testControllerDisconnectShowsTheOverlayWithoutKeyboardUse() {
        var state = OverlayVisibility()
        state.setExtendedController(true, isFirstController: true)
        state.noteAllControllersDisconnected()
        XCTAssertEqual(state.hidden, false)
    }

    func testDisconnectClearsTheManualOverride() {
        var state = OverlayVisibility()
        state.setExtendedController(true, isFirstController: true)
        state.noteManualToggle()
        state.noteAllControllersDisconnected()
        XCTAssertEqual(state.hidden, false)
    }

    func testFirstExtendedControllerClearsTheManualOverride() {
        var state = OverlayVisibility()
        state.noteManualToggle()
        state.setExtendedController(true, isFirstController: true)
        XCTAssertEqual(state.hidden, true)
    }

    func testLaterControllerKeepsTheManualChoice() {
        var state = OverlayVisibility()
        state.setExtendedController(true, isFirstController: true)
        state.noteManualToggle()
        state.setExtendedController(true, isFirstController: false)
        XCTAssertNil(state.hidden)
    }
}

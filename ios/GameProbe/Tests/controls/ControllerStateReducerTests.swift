import XCTest

@testable import GameProbe

final class ControllerStateReducerTests: XCTestCase {

    func testAxisHysteresisCrossingSequence() {
        var reducer = ControllerStateReducer()
        let element = "lefttrigger"

        XCTAssertTrue(reducer.apply(controllerID: "a", element: element, value: 0.45, isAxis: true).isEmpty)
        let press = reducer.apply(controllerID: "a", element: element, value: 0.55, isAxis: true)
        XCTAssertEqual(press, [ControllerStateReducer.Edge(element: element, pressed: true)])

        XCTAssertTrue(reducer.apply(controllerID: "a", element: element, value: 0.45, isAxis: true).isEmpty)
        let release = reducer.apply(controllerID: "a", element: element, value: 0.35, isAxis: true)
        XCTAssertEqual(release, [ControllerStateReducer.Edge(element: element, pressed: false)])
    }

    func testORMergeAcrossTwoControllers() {
        var reducer = ControllerStateReducer()
        let element = "a"

        let pressA = reducer.apply(controllerID: "pad-a", element: element, value: 1, isAxis: false)
        XCTAssertEqual(pressA, [ControllerStateReducer.Edge(element: element, pressed: true)])

        XCTAssertTrue(
            reducer.apply(controllerID: "pad-b", element: element, value: 1, isAxis: false).isEmpty
        )

        XCTAssertTrue(
            reducer.apply(controllerID: "pad-a", element: element, value: 0, isAxis: false).isEmpty
        )
        XCTAssertEqual(reducer.mergedPressedElements, [element])

        let releaseB = reducer.apply(controllerID: "pad-b", element: element, value: 0, isAxis: false)
        XCTAssertEqual(releaseB, [ControllerStateReducer.Edge(element: element, pressed: false)])
    }

    func testStickUpMapsToNegativeLeftY() {
        let samples = ControllerStickMapper.halfAxisSamples(stick: "left", x: 0, y: 0.8)
        XCTAssertEqual(samples.first { $0.element == "-lefty" }?.value, 0.8)
        XCTAssertEqual(samples.first { $0.element == "+lefty" }?.value, 0)

        var reducer = ControllerStateReducer()
        let press = reducer.apply(controllerID: "pad", element: "-lefty", value: 0.8, isAxis: true)
        XCTAssertEqual(press, [ControllerStateReducer.Edge(element: "-lefty", pressed: true)])
    }

    func testBuiltinMapContainsSpecDefaults() {
        let map = ControllerBuiltinMap.builtinResolved()
        XCTAssertEqual(map["a"], .key(40))
        XCTAssertEqual(map["b"], .key(41))
        XCTAssertEqual(map["x"], .key(225))
        XCTAssertEqual(map["start"], .action("$pauseMenu"))
        XCTAssertEqual(map["back"], .action("$toggleTouchControls"))
        XCTAssertNil(map["guide"])
    }

    func testRemoveControllerEmitsReleaseWhenLastHolderDisconnects() {
        var reducer = ControllerStateReducer()
        _ = reducer.apply(controllerID: "pad", element: "b", value: 1, isAxis: false)
        let release = reducer.removeController("pad")
        XCTAssertEqual(release, [ControllerStateReducer.Edge(element: "b", pressed: false)])
    }
}

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
        let active = ControllerStickMapper.directions(x: 0, y: 0.8, held: [])
        XCTAssertEqual(active, [.up])
        let samples = ControllerStickMapper.halfAxisSamples(stick: "left", x: 0, y: 0.8, active: active)
        XCTAssertEqual(samples.first { $0.element == "-lefty" }?.value, 0.8)
        XCTAssertEqual(samples.first { $0.element == "+lefty" }?.value, 0)

        var reducer = ControllerStateReducer()
        let press = reducer.apply(controllerID: "pad", element: "-lefty", value: 0.8, isAxis: true)
        XCTAssertEqual(press, [ControllerStateReducer.Edge(element: "-lefty", pressed: true)])
    }

    func testStickNearAnAxisSendsThatAxisAlone() {
        // 25 degrees above the x axis.
        XCTAssertEqual(ControllerStickMapper.directions(x: 0.8, y: 0.37, held: []), [.right])
        // 25 degrees left of straight down.
        XCTAssertEqual(ControllerStickMapper.directions(x: -0.37, y: -0.8, held: []), [.down])
    }

    func testStickDiagonalSendsBothDirectionsInOneSample() {
        let active = ControllerStickMapper.directions(x: 0.6, y: 0.6, held: [])
        XCTAssertEqual(active, [.up, .right])
        let samples = ControllerStickMapper.halfAxisSamples(stick: "left", x: 0.6, y: 0.6, active: active)
        let magnitude = (0.72 as Float).squareRoot()
        XCTAssertEqual(samples.first { $0.element == "+leftx" }?.value, magnitude)
        XCTAssertEqual(samples.first { $0.element == "-lefty" }?.value, magnitude)
        XCTAssertEqual(samples.first { $0.element == "-leftx" }?.value, 0)
        XCTAssertEqual(samples.first { $0.element == "+lefty" }?.value, 0)
    }

    func testStickSectorBoundaryHasHysteresis() {
        // 33 degrees: past the 30 degree boundary, inside the 5 degree margin.
        let x: Float = 0.75, y: Float = 0.49
        XCTAssertEqual(ControllerStickMapper.directions(x: x, y: y, held: [.right]), [.right])
        XCTAssertEqual(ControllerStickMapper.directions(x: x, y: y, held: []), [.up, .right])
        XCTAssertEqual(ControllerStickMapper.directions(x: x, y: y, held: [.up, .right]), [.up, .right])
        // 27 degrees: back inside the cardinal sector, inside the margin for a held diagonal.
        XCTAssertEqual(ControllerStickMapper.directions(x: 0.8, y: 0.41, held: [.up, .right]), [.up, .right])
        XCTAssertEqual(ControllerStickMapper.directions(x: 0.8, y: 0.41, held: []), [.right])
        // 40 degrees: past the margin, the held cardinal lets go.
        XCTAssertEqual(ControllerStickMapper.directions(x: 0.7, y: 0.59, held: [.right]), [.up, .right])
    }

    func testStickSwingBetweenAxesIgnoresTheOldSector() {
        XCTAssertEqual(ControllerStickMapper.directions(x: 0, y: 0.9, held: [.right]), [.up])
        XCTAssertEqual(ControllerStickMapper.directions(x: -0.9, y: 0, held: [.up, .right]), [.left])
    }

    func testStickAtRestSendsNothing() {
        XCTAssertEqual(ControllerStickMapper.directions(x: 0.25, y: 0.25, held: [.up, .right]), [])
        let samples = ControllerStickMapper.halfAxisSamples(stick: "left", x: 0.25, y: 0.25, active: [])
        XCTAssertTrue(samples.allSatisfy { $0.value == 0 })
    }

    func testStickMagnitudeIsCapped() {
        let samples = ControllerStickMapper.halfAxisSamples(stick: "right", x: 1, y: 1, active: [.up, .right])
        XCTAssertEqual(samples.first { $0.element == "+rightx" }?.value, 1)
    }

    func testBuiltinMapContainsSpecDefaults() {
        let map = BindingResolver.resolveRuntime().elements
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

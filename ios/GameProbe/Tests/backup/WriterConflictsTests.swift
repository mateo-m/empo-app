import Foundation
import XCTest

@testable import GameProbe

/// The writer question and its answer, per SPEC 5.12.
final class WriterConflictsTests: XCTestCase {

    private let claim = WriterClaim(
        namespaceId: "ns-1", deviceId: "device-b", deviceName: "Other iPhone",
        claimedAt: Date(timeIntervalSince1970: 1_700_000_000))

    func testARunThatMeetsAClaimLeavesAQuestion() {
        var state = WriterConflicts()

        state.runEnded(targetId: "t1", stop: .writerConflict(claim), didSplit: false)

        XCTAssertEqual(state.questions["t1"], claim)
        XCTAssertNil(state.answer(for: "t1"))
        XCTAssertFalse(state.showsTheSplitLine)
    }

    func testTheSplitAnswerCarriesANewNamespace() {
        var state = WriterConflicts(questions: ["t1": claim])

        state.answer(targetId: "t1", resolution: .split)

        XCTAssertNil(state.questions["t1"])
        XCTAssertEqual(state.answer(for: "t1")?.resolution, .split)
        XCTAssertEqual(state.answer(for: "t1")?.splitNamespaceId?.count, 32)
    }

    func testTheTakeOverAnswerNamesNoNamespace() {
        var state = WriterConflicts(questions: ["t1": claim])

        state.answer(targetId: "t1", resolution: .takeOver)

        XCTAssertEqual(state.answer(for: "t1"), .init(resolution: .takeOver))
    }

    func testASplitRunSpendsTheAnswerAndShowsTheLine() {
        var state = WriterConflicts()
        state.answer(targetId: "t1", resolution: .split)

        state.runEnded(targetId: "t1", stop: nil, didSplit: true)

        XCTAssertNil(state.answer(for: "t1"))
        XCTAssertTrue(state.showsTheSplitLine)
    }

    func testARunWithAnotherStopSpendsTheAnswerToo() {
        var state = WriterConflicts()
        state.answer(targetId: "t1", resolution: .takeOver)

        state.runEnded(targetId: "t1", stop: .offline, didSplit: false)

        XCTAssertNil(state.answer(for: "t1"))
        XCTAssertNil(state.questions["t1"])
    }

    func testTheStateSurvivesAJSONRoundTrip() throws {
        var state = WriterConflicts(questions: ["t1": claim], showsTheSplitLine: true)
        state.answer(targetId: "t2", resolution: .split)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        let decoded = try decoder.decode(WriterConflicts.self, from: try state.jsonData())

        XCTAssertEqual(decoded, state)
    }

    func testTheQuestionNamesTheOtherDeviceAndTheTarget() {
        XCTAssertEqual(
            WriterConflictQuestion.line(deviceName: "Other iPhone", targetLabel: "bob"),
            "Other iPhone also backs up to bob. Where should new backups from this device go?")
        XCTAssertEqual(WriterConflictQuestion.defaultResolution, .split)
        XCTAssertEqual(WriterConflictQuestion.label(of: .split), "Keep separate")
        XCTAssertEqual(WriterConflictQuestion.label(of: .takeOver), "Take over")
    }
}

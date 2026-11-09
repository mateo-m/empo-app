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
        guard case .split(let namespaceId) = state.answer(for: "t1") else {
            return XCTFail("no split answer")
        }
        XCTAssertEqual(namespaceId.count, 32)
    }

    func testTheTakeOverAnswerNamesNoNamespace() {
        var state = WriterConflicts(questions: ["t1": claim])

        state.answer(targetId: "t1", resolution: .takeOver)

        XCTAssertEqual(state.answer(for: "t1"), .takeOver)
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

    func testASavedAnswerKeepsItsShapeOnDisk() throws {
        let decoder = JSONDecoder()
        let split = Data(#"{"resolution":"split","splitNamespaceId":"ns-9"}"#.utf8)
        let takeOver = Data(#"{"resolution":"take-over"}"#.utf8)

        XCTAssertEqual(
            try decoder.decode(WriterConflicts.Answer.self, from: split),
            .split(namespaceId: "ns-9"))
        XCTAssertEqual(try decoder.decode(WriterConflicts.Answer.self, from: takeOver), .takeOver)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(WriterConflicts.Answer.split(namespaceId: "ns-9")))
                as? [String: String],
            ["resolution": "split", "splitNamespaceId": "ns-9"])
    }

    func testASavedSplitWithNoNamespaceGetsANewOne() throws {
        let saved = Data(#"{"resolution":"split"}"#.utf8)

        let answer = try JSONDecoder().decode(WriterConflicts.Answer.self, from: saved)

        guard case .split(let namespaceId) = answer else { return XCTFail("no split answer") }
        XCTAssertEqual(namespaceId.count, 32)
    }

    func testTheStateSurvivesAJSONRoundTrip() throws {
        var state = WriterConflicts(questions: ["t1": claim], showsTheSplitLine: true)
        state.answer(targetId: "t2", resolution: .split)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        let decoded = try decoder.decode(WriterConflicts.self, from: try state.jsonData())

        XCTAssertEqual(decoded, state)
    }

    func testAMissingFileReadsAsNoQuestion() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-conflicts-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(try WriterConflicts.read(applicationSupport: support), WriterConflicts())
    }

    func testADamagedFileMovesAsideAndReadsAsEmpty() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-conflicts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let damaged = Data("{\"questions\":".utf8)
        try damaged.write(to: support.appendingPathComponent(WriterConflicts.fileName))

        XCTAssertEqual(try WriterConflicts.read(applicationSupport: support), WriterConflicts())
        let kept = try FileManager.default.contentsOfDirectory(atPath: support.path)
            .filter { $0.hasPrefix(WriterConflicts.fileName + ".damaged-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: support.appendingPathComponent(try XCTUnwrap(kept.first))),
            damaged)
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

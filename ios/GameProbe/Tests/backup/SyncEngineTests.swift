import Foundation
import XCTest

@testable import GameProbe

/// The order of the six steps of SPEC 10.5.
///
/// The engine takes its document, its targets, and its two state
/// files as inputs, so this suite drives all four. The Automerge
/// half stays in the app, and the document here merges plain models.
@MainActor
final class SyncEngineTests: XCTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The fakes

    /// A document that merges plain models, key by key, the way
    /// Automerge merges leaves.
    private final class FakeDocument: SyncDocumentStore {
        var held = SyncDocumentModel()
        var saved: SyncDocumentModel?
        var loads = 0
        var writes: [SyncDocumentModel] = []
        /// What the engine did, in order.
        var steps: [String] = []
        var rejects: SyncCopyRejection?
        var losing: [String: [String: JSONValue]] = [:]
        var resolved: [String] = []

        func load() {
            loads += 1
            steps.append("load")
        }
        func model() throws -> SyncDocumentModel { held }

        func write(_ model: SyncDocumentModel) throws {
            held = model
            writes.append(model)
            steps.append("write")
        }

        func merge(_ bytes: Data) -> Result<Void, SyncCopyRejection> {
            steps.append("merge")
            if let rejects { return .failure(rejects) }
            guard let values = try? JSONDecoder().decode([String: JSONValue].self, from: bytes)
            else { return .failure(.unreadable("the test copy did not read")) }
            // A copy that arrived wins over what the document held,
            // which is the case a local change has to survive.
            // A copy fills the keys the document does not hold. The
            // key both sides carry is the one the step order has to
            // protect.
            var copy = SyncDocumentModel()
            copy.preferences = values
            held = copy.overlaid(with: held)
            return .success(())
        }

        func heads() -> [String] { ["h1"] }

        func losingControls(profileId: String) -> [String: JSONValue] {
            losing[profileId] ?? [:]
        }

        func resolveControls(profileId: String, keys: [String]) {
            resolved.append(profileId)
            losing[profileId] = nil
        }

        func save() throws {
            saved = held
            steps.append("save")
        }
    }

    private final class FakeTargets: SyncTargets {
        var descriptors: [TargetDescriptor] = []
        var held: [String: [SyncNamespace]] = [:]
        var bytes: [String: Data] = [:]
        var written: [String: Data] = [:]
        var refuses: Set<String> = []
        var puts: [String] = []

        func enabled() -> [TargetDescriptor] { descriptors }

        func namespaces(of target: TargetDescriptor) async -> [SyncNamespace] {
            held[target.id] ?? []
        }

        func read(_ path: String, from target: TargetDescriptor) async -> Data? {
            bytes[path]
        }

        func write(_ data: Data, to path: String, on target: TargetDescriptor) async -> Bool {
            written[path] = data
            return true
        }

        func putTheDocument(to path: String, on target: TargetDescriptor) async -> String? {
            guard !refuses.contains(target.id) else { return "the target said no" }
            puts.append(target.id)
            return nil
        }
    }

    private final class FakeState: SyncStateStore {
        var value: SyncState
        var identities = SyncProfileIdentities()
        /// A join that lands in the middle of one pass.
        var joinsMidPass: String?
        var reads = 0

        init(groupId: String?) {
            value = SyncState(actorId: "actor", groupId: groupId)
        }

        func state() -> SyncState {
            reads += 1
            if reads > 1, let joinsMidPass {
                value.groupId = joinsMidPass
                self.joinsMidPass = nil
            }
            return value
        }

        func update(_ change: (inout SyncState) -> Void) throws { change(&value) }

        func updateIdentities(_ change: (inout SyncProfileIdentities) -> Void) throws {
            change(&identities)
        }
    }

    private final class FakeLocalValues: SyncLocalValuesStore {
        var mine = SyncDocumentModel()
        var applied: [SyncDocumentModel] = []

        func read(identities: inout SyncProfileIdentities) -> SyncDocumentModel { mine }

        func apply(_ model: SyncDocumentModel, identities: inout SyncProfileIdentities) {
            applied.append(model)
        }
    }

    private func target(_ id: String) -> TargetDescriptor {
        TargetDescriptor(id: id, provider: .webdav, label: id, root: "Empo")
    }

    private func namespace(
        _ id: String, group: String?, modifiedAt: Date?
    ) -> SyncNamespace {
        SyncNamespace(
            id: id,
            record: DeviceRecord(
                deviceId: id, model: "iPad", name: "the \(id) device", lastWriteAt: stamp,
                syncGroupId: group),
            document: modifiedAt.map {
                RemoteObject(path: "\(id)/document", sizeBytes: 10, modifiedAt: $0)
            })
    }

    private func engine(
        document: FakeDocument, targets: FakeTargets, state: FakeState, local: FakeLocalValues,
        note: @escaping @MainActor (String) -> Void = { _ in }
    ) -> SyncEngine {
        SyncEngine(
            document: document, targets: targets, state: state, local: local,
            device: DeviceRecord(
                deviceId: "mine", model: "iPhone", name: "my phone", lastWriteAt: stamp),
            namespaceId: "mine", now: { self.stamp }, note: note)
    }

    /// One copy of the document as a test writes it: the
    /// preferences alone, which is what these cases carry.
    private func copyBytes(_ preferences: [String: JSONValue] = [:]) throws -> Data {
        try JSONEncoder().encode(preferences)
    }

    // MARK: - Step 3 goes in before step 2

    func testALocalChangeSurvivesACopyThatArrivesInTheSamePass() async throws {
        let document = FakeDocument()
        document.held.preferences = ["theme": .string("light")]
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]

        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes([
            "theme": .string("light"), "titlePosition": .string("below"),
        ])

        let state = FakeState(groupId: "g1")
        let outcome = await engine(
            document: document, targets: targets, state: state, local: local
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        // Step 3 goes in before step 2. A copy that arrived first
        // would write over the local change, and the user would
        // watch their change come undone.
        XCTAssertEqual(document.steps, ["load", "write", "merge", "save"])
        XCTAssertEqual(document.saved?.preferences["theme"], .string("dark"))
        XCTAssertEqual(document.saved?.preferences["titlePosition"], .string("below"))
        XCTAssertEqual(local.applied.count, 1)
    }

    // MARK: - The pass stops feeding itself

    func testAPassAfterALocalChangeWithNothingNewStopsBeforeItWrites() async throws {
        let document = FakeDocument()
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        let engine = engine(
            document: document, targets: targets, state: state, local: local)

        var outcome = await engine.run(.afterALocalChange)
        XCTAssertEqual(outcome, .done)
        let writes = document.writes.count

        // Step 4 posts the news a local change posts, so the same
        // values come back. The second pass reads them and stops.
        outcome = await engine.run(.afterALocalChange)
        XCTAssertEqual(outcome, .noLocalNews)
        XCTAssertEqual(document.writes.count, writes)

        local.mine.preferences["theme"] = .string("light")
        outcome = await engine.run(.afterALocalChange)
        XCTAssertEqual(outcome, .done)
        XCTAssertGreaterThan(document.writes.count, writes)
    }

    // MARK: - Step 1 reads the group and nothing else

    func testACopyOfAnotherGroupAndThisDevicesOwnCopyAreNeverRead() async throws {
        let document = FakeDocument()
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [
            namespace("stranger", group: "g2", modifiedAt: stamp),
            namespace("mine", group: "g1", modifiedAt: stamp),
            namespace("nogroup", group: nil, modifiedAt: stamp),
        ]
        for id in ["stranger", "mine", "nogroup"] {
            targets.bytes["\(id)/document"] = try copyBytes(["theme": .string("stranger")])
        }

        let state = FakeState(groupId: "g1")
        let outcome = await engine(
            document: document, targets: targets, state: state, local: FakeLocalValues()
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        XCTAssertNil(document.saved?.preferences["theme"])
        XCTAssertTrue(state.value.targets.first?.seenNamespaces.isEmpty ?? true)
    }

    /// The pass reads one copy once, per 10.5 step 1.
    func testACopyThatDidNotMoveIsNotReadAgain() async throws {
        let document = FakeDocument()
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes()

        let state = FakeState(groupId: "g1")
        let engine = engine(
            document: document, targets: targets, state: state, local: FakeLocalValues())

        _ = await engine.run(.now)
        XCTAssertEqual(state.value.progress(ofTarget: "t1")?.seenNamespaces["other"], stamp)

        targets.bytes["other/document"] = nil
        // A second pass that read it again would find no bytes and
        // change nothing, so the state row is the proof.
        _ = await engine.run(.now)
        XCTAssertEqual(state.value.progress(ofTarget: "t1")?.seenNamespaces["other"], stamp)
    }

    // MARK: - Step 2's rejections

    func testARejectedCopyChangesNothingAndSaysWhy() async throws {
        let document = FakeDocument()
        document.rejects = .unsupported(minimumWriterVersion: 9)
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = Data("anything".utf8)

        var notes: [String] = []
        let state = FakeState(groupId: "g1")
        let outcome = await engine(
            document: document, targets: targets, state: state, local: FakeLocalValues(),
            note: { notes.append($0) }
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        XCTAssertTrue(notes.contains { $0.contains("other changed nothing") })
        // A copy that changed nothing leaves no state row, so the
        // pass reads it again when the target answers again.
        XCTAssertNil(state.value.progress(ofTarget: "t1")?.seenNamespaces["other"])
    }

    /// A document this build may not write still applies here, per
    /// 10.10.
    func testABuildThatMayNotWriteAppliesTheDocumentAndPublishesNothing() async throws {
        let document = FakeDocument()
        document.held.minimumWriterVersion = SyncSchema.currentVersion + 1
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")

        let outcome = await engine(
            document: document, targets: targets, state: state, local: local
        ).run(.now)

        XCTAssertEqual(outcome, .failed("this build reads the document but does not write it"))
        XCTAssertEqual(local.applied.count, 1)
        XCTAssertTrue(document.writes.isEmpty)
        XCTAssertNil(document.saved)
        XCTAssertTrue(targets.puts.isEmpty)
    }

    // MARK: - Steps 5 and 6

    func testATargetThatRefusesTheCopyTakesNothingFromTheOthers() async throws {
        let document = FakeDocument()
        let targets = FakeTargets()
        targets.descriptors = [target("t1"), target("t2")]
        targets.refuses = ["t1"]

        var notes: [String] = []
        let state = FakeState(groupId: "g1")
        let outcome = await engine(
            document: document, targets: targets, state: state, local: FakeLocalValues(),
            note: { notes.append($0) }
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(targets.puts, ["t2"])
        XCTAssertTrue(notes.contains { $0.contains("t1 took no copy: the target said no") })
        // Only the target that took the copy holds the heads, so the
        // next pass tries the other one again.
        XCTAssertNil(state.value.progress(ofTarget: "t1")?.confirmedHeads)
        XCTAssertEqual(state.value.progress(ofTarget: "t2")?.confirmedHeads, ["h1"])
        // The device record of 10.5 step 1 carries the group id, and
        // only the target that took the copy gets one.
        let record = try XCTUnwrap(targets.written.values.first)
        XCTAssertEqual(try DeviceRecord.decode(json: record).syncGroupId, "g1")
        XCTAssertEqual(targets.written.count, 1)
    }

    func testATargetThatHoldsTheHeadsTakesNoSecondCopy() async throws {
        let document = FakeDocument()
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        let engine = engine(
            document: document, targets: targets, state: state, local: FakeLocalValues())

        _ = await engine.run(.now)
        _ = await engine.run(.now)
        XCTAssertEqual(targets.puts, ["t1"])
    }

    func testAJoinInTheMiddleOfAPassPublishesNothingToTheGroupItLeft() async throws {
        let document = FakeDocument()
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        state.joinsMidPass = "g2"

        let outcome = await engine(
            document: document, targets: targets, state: state, local: FakeLocalValues()
        ).run(.now)

        XCTAssertEqual(outcome, .runAgain)
        XCTAssertTrue(targets.puts.isEmpty)
        XCTAssertTrue(targets.written.isEmpty)
    }

    // MARK: - The conflict rule of 10.6

    func testAControlTheMergeCouldNotPickBecomesAProfileOfItsOwn() async throws {
        let document = FakeDocument()
        document.held.layoutProfiles = [
            "p1": SyncProfile(name: "Pad", controls: ["a": .string("left")])
        ]
        document.losing = ["p1": ["a": .string("right")]]

        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes()

        let state = FakeState(groupId: "g1")
        let outcome = await engine(
            document: document, targets: targets, state: state, local: FakeLocalValues()
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        let saved = try XCTUnwrap(document.saved)
        let conflict = try XCTUnwrap(saved.layoutProfiles.first { $0.key != "p1" })
        XCTAssertEqual(conflict.value.controls["a"], .string("right"))
        XCTAssertTrue(conflict.value.name.contains("the other device"))
        XCTAssertEqual(saved.layoutProfiles["p1"]?.name, "Pad")
        // The winner goes back on the leaf, or the same conflict
        // answers every later pass.
        XCTAssertEqual(document.resolved, ["p1"])
    }

    // MARK: - What stops a pass before it starts

    func testAPassWithNoGroupAndAPassWithNoTargetDoNothing() async throws {
        let targets = FakeTargets()
        let noGroup = FakeDocument()
        var outcome = await engine(
            document: noGroup, targets: targets, state: FakeState(groupId: nil),
            local: FakeLocalValues()
        ).run(.now)
        XCTAssertEqual(outcome, .nothingToDo)
        XCTAssertEqual(noGroup.loads, 0)

        let noTarget = FakeDocument()
        outcome = await engine(
            document: noTarget, targets: targets, state: FakeState(groupId: "g1"),
            local: FakeLocalValues()
        ).run(.now)
        XCTAssertEqual(outcome, .nothingToDo)
        XCTAssertEqual(noTarget.loads, 0)
    }

    /// A join deletes the file, per 10.4, so every pass starts from
    /// the file.
    func testEveryPassReadsTheDocumentFromTheFileAgain() async throws {
        let document = FakeDocument()
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let engine = engine(
            document: document, targets: targets, state: FakeState(groupId: "g1"),
            local: FakeLocalValues())

        _ = await engine.run(.now)
        _ = await engine.run(.now)
        XCTAssertEqual(document.loads, 2)
    }
}

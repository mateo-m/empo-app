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
        var losing: [String: [[String: JSONValue]]] = [:]
        var failsToWrite = false
        var resolved: [String] = []

        func load() {
            loads += 1
            steps.append("load")
        }
        func model() throws -> SyncDocumentModel { held }

        func write(_ model: SyncDocumentModel) throws {
            if failsToWrite { throw CocoaError(.fileWriteNoPermission) }
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

        var heldHeads = ["h1"]
        func heads() -> [String] { heldHeads }

        func losingControls(profileId: String) -> [[String: JSONValue]] {
            losing[profileId] ?? []
        }

        func resolveControls(profileId: String, keys: [String]) {
            resolved.append(profileId)
            losing[profileId] = nil
        }

        var failsToSave = false

        func save() throws {
            if failsToSave { throw CocoaError(.fileWriteNoPermission) }
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
        var unlisted: Set<String> = []
        var puts: [String] = []
        var duringRead: (() -> Void)?

        func enabled() -> [TargetDescriptor] { descriptors }

        func namespaces(of target: TargetDescriptor) async -> [SyncNamespace]? {
            unlisted.contains(target.id) ? nil : held[target.id] ?? []
        }

        func read(_ path: String, from target: TargetDescriptor) async -> Data? {
            duringRead?()
            return bytes[path]
        }

        var refusesWrites = false

        func write(_ data: Data, to path: String, on target: TargetDescriptor) async -> Bool {
            guard !refusesWrites else { return false }
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

        var failsToRead = false

        func state() throws -> SyncState {
            if failsToRead { throw CocoaError(.fileReadCorruptFile) }
            reads += 1
            if reads > 1, let joinsMidPass {
                value.groupId = joinsMidPass
                self.joinsMidPass = nil
            }
            return value
        }

        var failsToUpdate = false

        func update(_ change: (inout SyncState) -> Void) throws {
            if failsToUpdate { throw CocoaError(.fileWriteNoPermission) }
            change(&value)
        }

        var failsToUpdateIdentities = false

        func updateIdentities(_ change: (inout SyncProfileIdentities) -> Void) throws {
            if failsToUpdateIdentities { throw CocoaError(.fileWriteNoPermission) }
            change(&identities)
        }
    }

    private final class FakeLocalValues: SyncLocalValuesStore {
        var mine = SyncDocumentModel()
        var applied: [SyncDocumentModel] = []

        func read(identities: inout SyncProfileIdentities) -> SyncDocumentModel { mine }

        func apply(_ model: SyncDocumentModel, identities: inout SyncProfileIdentities) {
            applied.append(model)
            if !model.controllerBindings.isEmpty { mine.controllerBindings = model.controllerBindings }
        }
    }

    private func target(_ id: String) -> TargetDescriptor {
        TargetDescriptor(id: id, provider: .webdav, label: id, root: "Empo")
    }

    private func namespace(
        _ id: String, group: String?, modifiedAt: Date?, sizeBytes: Int64 = 10
    ) -> SyncNamespace {
        SyncNamespace(
            id: id,
            record: DeviceRecord(
                deviceId: id, model: "iPad", name: "the \(id) device", lastWriteAt: stamp,
                syncGroupId: group),
            document: modifiedAt.map {
                RemoteObject(path: "\(id)/document", sizeBytes: sizeBytes, modifiedAt: $0)
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

    /// A settings restore can land while the pass downloads. The
    /// values the pass read before are old by then.
    func testALocalChangeDuringTheDownloadIsNotWrittenOver() async throws {
        let document = FakeDocument()
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes(["titlePosition": .string("below")])
        targets.duringRead = { local.mine.preferences["theme"] = .string("restored") }
        let state = FakeState(groupId: "g1")
        let engine = engine(document: document, targets: targets, state: state, local: local)

        let first = await engine.run(.now)
        XCTAssertEqual(first, .runAgain)
        XCTAssertTrue(local.applied.isEmpty)
        XCTAssertNil(document.saved)

        targets.duringRead = nil
        let second = await engine.run(.now)
        XCTAssertEqual(second, .done)
        XCTAssertEqual(local.applied.last?.preferences["theme"], .string("restored"))
        XCTAssertEqual(document.saved?.preferences["theme"], .string("restored"))
    }

    /// A rollback of 10.9 removed a key here. A missing local key is
    /// not a delete, so the key travels as a removal by name.
    func testAPreferenceARollbackRemovedLeavesTheDocument() async throws {
        let document = FakeDocument()
        document.held.preferences = ["theme": .string("light"), "titlePosition": .string("below")]
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("light")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        state.value.removedPreferenceKeys = ["titlePosition"]

        let outcome = await engine(
            document: document, targets: targets, state: state, local: local
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(document.saved?.preferences, ["theme": .string("light")])
        XCTAssertEqual(state.value.removedPreferenceKeys, [])
    }

    func testARemovalThatDidNotClearDoesNotDeleteAValueSetAgain() async throws {
        let document = FakeDocument()
        document.held.preferences = ["theme": .string("light"), "titlePosition": .string("below")]
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("light")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        state.value.removedPreferenceKeys = ["titlePosition"]
        state.failsToUpdate = true
        let engine = engine(document: document, targets: targets, state: state, local: local)

        let first = await engine.run(.now)
        XCTAssertEqual(first, .done)
        XCTAssertNil(document.saved?.preferences["titlePosition"])
        XCTAssertEqual(state.value.removedPreferenceKeys, ["titlePosition"])

        state.failsToUpdate = false
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes(["titlePosition": .string("above")])
        let second = await engine.run(.now)

        XCTAssertEqual(second, .done)
        XCTAssertEqual(document.saved?.preferences["titlePosition"], .string("above"))
        XCTAssertEqual(local.applied.last?.preferences["titlePosition"], .string("above"))
        XCTAssertEqual(state.value.removedPreferenceKeys, [])
    }

    /// A binding the user cleared here, or a settings restore took
    /// away, is missing from the local map. The pass deletes it from
    /// the document, or the merge would bring it back.
    func testABindingRemovedHereLeavesTheDocument() async throws {
        let document = FakeDocument()
        document.held.controllerBindings = ["a": .string("confirm"), "b": .string("cancel")]
        let local = FakeLocalValues()
        local.mine.controllerBindings = ["a": .string("confirm")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        state.value.heldBindingIds = ["a", "b"]

        let outcome = await engine(
            document: document, targets: targets, state: state, local: local
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(document.saved?.controllerBindings, ["a": .string("confirm")])
        XCTAssertEqual(state.value.heldBindingIds, ["a"])
    }

    /// A binding this device never held came from another device. It
    /// stays, and the device holds it after the pass.
    func testABindingAnotherDeviceAddedStays() async throws {
        let document = FakeDocument()
        document.held.controllerBindings = ["a": .string("confirm"), "b": .string("cancel")]
        let local = FakeLocalValues()
        local.mine.controllerBindings = ["a": .string("confirm")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        state.value.heldBindingIds = ["a"]

        let outcome = await engine(
            document: document, targets: targets, state: state, local: local
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(
            document.saved?.controllerBindings,
            ["a": .string("confirm"), "b": .string("cancel")])
        XCTAssertEqual(state.value.heldBindingIds, ["a", "b"])
    }

    /// A document with no history writes nothing of its own before
    /// the group's copies, or its root maps would hide the group's.
    /// The local values can be old, such as settings just restored
    /// from a snapshot, so the group's value wins a key both hold.
    func testANewDocumentTakesTheGroupsCopiesBeforeItsOwnValues() async throws {
        let document = FakeDocument()
        document.heldHeads = []
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark"), "layout": .string("grid")]

        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes([
            "theme": .string("light"), "titlePosition": .string("below"),
        ])

        let outcome = await engine(
            document: document, targets: targets, state: FakeState(groupId: "g1"), local: local
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(document.steps, ["load", "merge", "write", "save"])
        XCTAssertEqual(document.saved?.preferences["theme"], .string("light"))
        XCTAssertEqual(document.saved?.preferences["titlePosition"], .string("below"))
        XCTAssertEqual(document.saved?.preferences["layout"], .string("grid"))
        XCTAssertEqual(local.applied.last?.preferences["theme"], .string("light"))
    }

    /// The local document was lost after earlier passes. The copies
    /// those passes read belong to the lost history, so the new
    /// document reads them again.
    func testALostDocumentReadsTheCopiesAnEarlierPassAlreadyRead() async throws {
        let document = FakeDocument()
        document.heldHeads = []
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]

        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes(["titlePosition": .string("below")])

        let state = FakeState(groupId: "g1")
        state.value.targets = [
            SyncTargetProgress(
                targetId: "t1", confirmedHeads: ["lost"], seenNamespaces: ["other": stamp])
        ]

        let outcome = await engine(
            document: document, targets: targets, state: state, local: local
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(document.steps, ["load", "merge", "write", "save"])
        XCTAssertEqual(document.saved?.preferences["titlePosition"], .string("below"))
        XCTAssertEqual(targets.puts, ["t1"])
    }

    func testANewDocumentWritesNothingWhileATargetDoesNotList() async throws {
        let document = FakeDocument()
        document.heldHeads = []
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.unlisted = ["t1"]

        let outcome = await engine(
            document: document, targets: targets, state: FakeState(groupId: "g1"), local: local
        ).run(.now)

        XCTAssertEqual(outcome, .failed("a new document waits for every copy of the group"))
        XCTAssertEqual(document.steps, ["load"])
        XCTAssertTrue(local.applied.isEmpty)
        XCTAssertTrue(targets.puts.isEmpty)
    }

    func testANewDocumentWritesNothingWhileACopyDoesNotRead() async throws {
        let document = FakeDocument()
        document.heldHeads = []
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]

        let outcome = await engine(
            document: document, targets: targets, state: FakeState(groupId: "g1"), local: local
        ).run(.now)

        XCTAssertEqual(outcome, .failed("a new document waits for every copy of the group"))
        XCTAssertEqual(document.steps, ["load"])
        XCTAssertTrue(local.applied.isEmpty)
        XCTAssertTrue(targets.puts.isEmpty)
    }

    func testANewDocumentWritesNothingWhileACopyIsRejected() async throws {
        let document = FakeDocument()
        document.heldHeads = []
        document.rejects = .unreadable("truncated")
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = Data("anything".utf8)

        let outcome = await engine(
            document: document, targets: targets, state: FakeState(groupId: "g1"), local: local
        ).run(.now)

        XCTAssertEqual(outcome, .failed("a new document waits for every copy of the group"))
        XCTAssertEqual(document.steps, ["load", "merge"])
        XCTAssertTrue(local.applied.isEmpty)
        XCTAssertTrue(targets.puts.isEmpty)
    }

    func testANewDocumentWritesNothingWhileTheDeviceRecordOfACopyDoesNotRead() async throws {
        let document = FakeDocument()
        document.heldHeads = []
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [
            SyncNamespace(
                id: "other", record: nil,
                document: RemoteObject(path: "other/document", sizeBytes: 10, modifiedAt: stamp))
        ]

        let outcome = await engine(
            document: document, targets: targets, state: FakeState(groupId: "g1"), local: local
        ).run(.now)

        XCTAssertEqual(outcome, .failed("a new document waits for every copy of the group"))
        XCTAssertTrue(local.applied.isEmpty)
        XCTAssertTrue(targets.puts.isEmpty)
    }

    func testProfileIdsThatDoNotSaveStopThePass() async throws {
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        state.failsToUpdateIdentities = true

        let outcome = await engine(
            document: FakeDocument(), targets: targets, state: state, local: local
        ).run(.now)

        guard case .failed(let reason) = outcome else {
            return XCTFail("the pass went on with ids that did not save: \(outcome)")
        }
        XCTAssertTrue(reason.hasPrefix("the profile identities were not saved"))
        XCTAssertTrue(local.applied.isEmpty)
        XCTAssertTrue(targets.puts.isEmpty)
    }

    func testALostDocumentWritesNothingWhileItsReadProgressStays() async throws {
        let document = FakeDocument()
        document.heldHeads = []
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes(["titlePosition": .string("below")])
        let state = FakeState(groupId: "g1")
        state.value.targets = [
            SyncTargetProgress(
                targetId: "t1", confirmedHeads: ["lost"], seenNamespaces: ["other": stamp])
        ]
        state.failsToUpdate = true

        let outcome = await engine(
            document: document, targets: targets, state: state, local: local
        ).run(.now)

        guard case .failed = outcome else { return XCTFail("the pass went on: \(outcome)") }
        XCTAssertEqual(document.steps, ["load"])
        XCTAssertTrue(local.applied.isEmpty)
        XCTAssertTrue(targets.puts.isEmpty)
    }

    func testTheFirstDeviceOfAGroupWritesWithNoCopyToRead() async throws {
        let document = FakeDocument()
        document.heldHeads = []
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]

        let outcome = await engine(
            document: document, targets: targets, state: FakeState(groupId: "g1"), local: local
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(document.saved?.preferences["theme"], .string("dark"))
        XCTAssertEqual(targets.puts, ["t1"])
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

    /// The pass applied a binding another device added. Removing it
    /// here brings the values back to what the pass read before the
    /// apply, and that is still news.
    func testALocalChangeBackToTheValuesBeforeTheApplyIsNews() async throws {
        let document = FakeDocument()
        document.held.controllerBindings = ["a": .string("confirm"), "c": .string("menu")]
        let local = FakeLocalValues()
        local.mine.controllerBindings = ["a": .string("confirm")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        state.value.heldBindingIds = ["a"]
        let engine = engine(document: document, targets: targets, state: state, local: local)

        var outcome = await engine.run(.afterALocalChange)
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(local.mine.controllerBindings["c"], .string("menu"))

        local.mine.controllerBindings = ["a": .string("confirm")]
        outcome = await engine.run(.afterALocalChange)
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(document.saved?.controllerBindings, ["a": .string("confirm")])
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

    func testACopyWrittenAgainInTheSameSecondIsReadAgain() async throws {
        let document = FakeDocument()
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes()

        let state = FakeState(groupId: "g1")
        let engine = engine(
            document: document, targets: targets, state: state, local: FakeLocalValues())
        _ = await engine.run(.now)

        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp, sizeBytes: 12)]
        document.steps = []
        _ = await engine.run(.now)

        XCTAssertTrue(document.steps.contains("merge"))
        XCTAssertEqual(state.value.progress(ofTarget: "t1")?.seenSizes["other"], 12)
    }

    func testACopyAndALocalChangeAreTakenAgainAfterASaveThatFailed() async throws {
        let document = FakeDocument()
        document.failsToSave = true
        let local = FakeLocalValues()
        local.mine.preferences = ["theme": .string("dark")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes(["layout": .string("list")])

        let state = FakeState(groupId: "g1")
        let engine = engine(document: document, targets: targets, state: state, local: local)

        guard case .failed = await engine.run(.afterALocalChange) else {
            return XCTFail("the pass did not report the failed save")
        }
        XCTAssertNil(state.value.progress(ofTarget: "t1")?.seenNamespaces["other"])

        document.failsToSave = false
        document.steps = []
        let outcome = await engine.run(.afterALocalChange)

        XCTAssertEqual(outcome, .done)
        XCTAssertTrue(document.steps.contains("merge"))
        XCTAssertEqual(state.value.progress(ofTarget: "t1")?.seenNamespaces["other"], stamp)
    }

    // MARK: - Step 2's rejections

    func testARejectedCopyChangesNothingAndSaysWhy() async throws {
        let document = FakeDocument()
        document.rejects = .unreadable("truncated")
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

    /// A build that may not write cannot delete the binding from the
    /// document, so the apply must not bring it back on every pass.
    func testABuildThatMayNotWriteKeepsABindingRemovedHereRemoved() async throws {
        let document = FakeDocument()
        document.held.minimumWriterVersion = SyncSchema.currentVersion + 1
        document.held.controllerBindings = ["a": .string("confirm"), "b": .string("cancel")]
        let local = FakeLocalValues()
        local.mine.controllerBindings = ["a": .string("confirm")]
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        state.value.heldBindingIds = ["a", "b"]
        let engine = engine(document: document, targets: targets, state: state, local: local)

        for _ in 0..<2 {
            let outcome = await engine.run(.now)
            XCTAssertEqual(outcome, .failed("this build reads the document but does not write it"))
            XCTAssertEqual(local.mine.controllerBindings, ["a": .string("confirm")])
        }
    }

    func testAJoinForgetsTheBindingsTheOldGroupHeld() {
        var state = SyncState(actorId: "actor", groupId: "g1", heldBindingIds: ["a"])
        state.join("g2")
        XCTAssertEqual(state.heldBindingIds, [])
    }

    // MARK: - Steps 5 and 6

    func testATargetWithoutTheDeviceRecordGetsTheCopyAgain() async throws {
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.refusesWrites = true
        let state = FakeState(groupId: "g1")

        let outcome = await engine(
            document: FakeDocument(), targets: targets, state: state, local: FakeLocalValues()
        ).run(.now)

        XCTAssertEqual(outcome, .done)
        XCTAssertNil(state.value.progress(ofTarget: "t1")?.confirmedHeads)
    }

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
        document.losing = ["p1": [["a": .string("right")]]]

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

    func testEveryLosingVersionOfThreeDevicesKeepsAProfile() async throws {
        let document = FakeDocument()
        document.held.layoutProfiles = [
            "p1": SyncProfile(name: "Pad", controls: ["a": .string("left")])
        ]
        document.losing = ["p1": [["a": .string("right")], ["a": .string("up")]]]

        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes()

        let state = FakeState(groupId: "g1")
        _ = await engine(
            document: document, targets: targets, state: state, local: FakeLocalValues()
        ).run(.now)

        let saved = try XCTUnwrap(document.saved)
        let kept = saved.layoutProfiles.filter { $0.key != "p1" }
            .compactMap { $0.value.controls["a"] }
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.contains(.string("right")))
        XCTAssertTrue(kept.contains(.string("up")))
    }

    func testAConflictStaysUnresolvedWhenItsProfileIsNotWritten() async throws {
        let document = FakeDocument()
        document.held.layoutProfiles = [
            "p1": SyncProfile(name: "Pad", controls: ["a": .string("left")])
        ]
        document.losing = ["p1": [["a": .string("right")]]]

        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        targets.held["t1"] = [namespace("other", group: "g1", modifiedAt: stamp)]
        targets.bytes["other/document"] = try copyBytes()
        document.failsToWrite = true

        _ = await engine(
            document: document, targets: targets, state: FakeState(groupId: "g1"),
            local: FakeLocalValues()
        ).run(.now)

        XCTAssertTrue(document.resolved.isEmpty)
        XCTAssertNotNil(document.losing["p1"])
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

    func testASyncStateThatDoesNotReadFailsThePass() async throws {
        let document = FakeDocument()
        let targets = FakeTargets()
        targets.descriptors = [target("t1")]
        let state = FakeState(groupId: "g1")
        state.failsToRead = true

        let outcome = await engine(
            document: document, targets: targets, state: state, local: FakeLocalValues()
        ).run(.now)

        guard case .failed = outcome else { return XCTFail("the pass did not fail: \(outcome)") }
        XCTAssertTrue(document.steps.isEmpty)
        XCTAssertTrue(targets.puts.isEmpty)
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

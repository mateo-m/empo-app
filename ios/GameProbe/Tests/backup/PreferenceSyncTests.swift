import Foundation
import XCTest

@testable import GameProbe

/// The pure rules of SPEC section 10: the three classes of 10.1, the
/// game-scoped invariant of 10.2, the join of 10.4, the pass of
/// 10.5, the merge rules of 10.6, the descriptors of 10.8, the
/// rollback of 10.9, and the versions of 10.10.
///
/// The Automerge half lives in the app, because its FFI ships as an
/// Apple-only binary and this suite runs on Linux too. What that
/// leaves here is every rule that decides what goes into the
/// document and what comes out of it.
final class PreferenceSyncTests: XCTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 10.1

    func testEveryKeyOf101LandsInItsClass() {
        let portable = [
            "theme", "interfaceHaptics", "controllerHaptics", "controlsEditSnapToGrid",
            "libraryDisplayMode", "librarySortOption", "showContinuePlaying", "titlePosition",
            "cleanupInvalidGames", "controllerMap.global", "layoutProfiles.gameNoticeShown",
            "layoutProfiles.default",
        ]
        let deviceLocal = [
            "debugMode", "debugLogs", "maxLogFiles", "showViewportBounds", "showTouchZone",
            "pointerInjection", "vpBoundsR", "vpBoundsG", "vpBoundsB", "vpBoundsA",
        ]
        let neverStored = [
            "caBundleLastRefresh", "UpdateChecker.lastCheckedAt",
            "UpdateChecker.lastKnownLatestVersion", "pendingDuplicateGameNames",
            "pendingSaveRecoveries", "disclaimerAcknowledgedVersion",
        ]

        for key in portable {
            XCTAssertEqual(PreferenceKeys.classOf(key), .portable, key)
        }
        for key in deviceLocal {
            XCTAssertEqual(PreferenceKeys.classOf(key), .deviceLocal, key)
        }
        for key in neverStored {
            XCTAssertEqual(PreferenceKeys.classOf(key), .neverStored, key)
        }
        XCTAssertEqual(PreferenceKeys.classOf("hint.dismissed.controls"), .portable)
    }

    func testEveryNamedKeyCarriesOneClassAndNoKeyRepeats() {
        let names = PreferenceKeys.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for backupClass in PreferenceClass.allCases {
            XCTAssertFalse(PreferenceKeys.names(inClass: backupClass).isEmpty)
        }
    }

    func testAKeyNobodyNamedHasNoClass() {
        XCTAssertNil(PreferenceKeys.classOf("someKeyNobodyDeclared"))
    }

    // MARK: - 10.2

    func testTheExportCarriesNoGameScopedKey() throws {
        let defaults: [String: JSONValue] = [
            "theme": .string("dark"),
            "controlsLayout.com.example.quest": .string("{}"),
            "controllerMap.com.example.quest": .string("{}"),
            "controllerMap.global": .string("{}"),
            "debugMode": .bool(true),
        ]
        let values = PreferenceExport.portableValues(of: defaults)
        XCTAssertEqual(Set(values.keys), ["theme", "controllerMap.global"])
        for key in values.keys {
            XCTAssertFalse(PreferenceKeys.isGameScoped(key), key)
        }

        let document = try PreferenceExport.decode(
            json: try PreferenceExport.document(of: defaults, at: stamp))
        XCTAssertEqual(Set(document.values.keys), ["theme", "controllerMap.global"])
    }

    func testTheGlobalControllerMapIsNotGameScoped() {
        XCTAssertTrue(PreferenceKeys.isGameScoped("controllerMap.abc"))
        XCTAssertFalse(PreferenceKeys.isGameScoped("controllerMap.global"))
    }

    // MARK: - 10.4

    func testOneGroupAsksForAConfirmationAndSeveralAskForAPick() {
        let records = [
            record(name: "iPhone", group: "a"),
            record(name: "iPad", group: "a"),
            record(name: "iPod", group: "b"),
            record(name: "unjoined", group: nil),
        ]
        let groups = SyncGroupDiscovery.groups(in: records)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].deviceNames, ["iPad", "iPhone"])

        guard case .pick(let open) = SyncGroupDiscovery.ask(of: groups) else {
            return XCTFail("two groups ask for a pick")
        }
        XCTAssertEqual(open.count, 2)

        guard case .confirm(let one) = SyncGroupDiscovery.ask(of: groups, joined: groups[1].groupId)
        else { return XCTFail("one open group asks for a confirmation") }
        XCTAssertEqual(one.groupId, groups[0].groupId)
        XCTAssertEqual(SyncGroupDiscovery.ask(of: []), .none)
    }

    func testAGroupIdIsRandomHexAndOnlyValidInThatShape() {
        let id = SyncGroup.makeId()
        XCTAssertEqual(id.count, SyncGroup.idLength)
        XCTAssertTrue(SyncGroup.isValidId(id))
        XCTAssertNotEqual(id, SyncGroup.makeId())
        XCTAssertFalse(SyncGroup.isValidId(id.uppercased()))
        XCTAssertFalse(SyncGroup.isValidId(String(id.dropLast())))
    }

    func testTheJoinClearsWhatTheOldGroupConfirmed() {
        var state = SyncState(actorId: "actor")
        state.startAGroup(at: stamp)
        let first = state.groupId
        state.confirm(targetId: "t1", heads: ["b", "a"])
        XCTAssertEqual(state.progress(ofTarget: "t1")?.confirmedHeads, ["a", "b"])

        state.startAGroup(at: stamp)
        XCTAssertEqual(state.groupId, first, "a device with a group keeps it")

        state.join("f".repeated(32), at: stamp)
        XCTAssertTrue(state.targets.isEmpty)
    }

    // MARK: - 10.5

    func testANewTargetTakesACopyAndACurrentOneDoesNot() {
        let heads = ["aa", "bb"]
        let current = SyncTargetProgress(targetId: "t1", confirmedHeads: ["bb", "aa"])
        let behind = SyncTargetProgress(targetId: "t2", confirmedHeads: ["aa"])
        XCTAssertTrue(SyncReplication.isCurrent(current, heads: heads))
        XCTAssertFalse(SyncReplication.isCurrent(behind, heads: heads))
        XCTAssertFalse(SyncReplication.isCurrent(current, heads: []))

        XCTAssertEqual(
            SyncReplication.targetsNeedingACopy(
                enabled: ["t3", "t1", "t2"], progress: [current, behind], heads: heads),
            ["t2", "t3"])
    }

    func testACopyIsReadAgainOnlyWhenItMoved() {
        let progress = SyncTargetProgress(
            targetId: "t1", seenNamespaces: ["ns-1": stamp])
        XCTAssertFalse(progress.readsAgain(namespaceId: "ns-1", modifiedAt: stamp))
        XCTAssertTrue(
            progress.readsAgain(namespaceId: "ns-1", modifiedAt: stamp.addingTimeInterval(1)))
        XCTAssertTrue(progress.readsAgain(namespaceId: "ns-2", modifiedAt: stamp))
        XCTAssertTrue(
            progress.readsAgain(namespaceId: "ns-1", modifiedAt: nil),
            "a target that reports no object age is read every pass")
    }

    func testATruncatedAndACorruptCopyChangeNothing() {
        XCTAssertEqual(
            SyncCopyValidation.check(Data()) { _ in SyncDocumentModel() }.failure, .empty)

        let bytes = Data([0x85, 0x6F, 0x4A, 0x83])
        let rejection = SyncCopyValidation.check(bytes) { _ in
            throw SyncCopyRejection.unreadable("automerge said no")
        }.failure
        guard case .unreadable = rejection else {
            return XCTFail("a copy Automerge cannot read is rejected")
        }
    }

    func testThisDeviceDoesNotDeleteAKeyItNeverHeld() {
        var group = SyncDocumentModel()
        group.preferences = ["theme": .string("dark"), "titlePosition": .string("below")]
        group.controllerBindings = ["a": .string("Z")]
        var local = SyncDocumentModel()
        local.preferences = ["theme": .string("light")]

        let published = group.overlaid(with: local)
        XCTAssertEqual(published.preferences["theme"], .string("light"))
        XCTAssertEqual(published.preferences["titlePosition"], .string("below"))
        XCTAssertEqual(published.controllerBindings["a"], .string("Z"))
    }

    // MARK: - 10.6

    func testADeletionBeatsAConcurrentEdit() {
        let edited = SyncProfile(name: "Small hands", controls: ["portrait.dpad": .string("{}")])
        let deleted = SyncProfile(name: "Small hands", deletedAt: stamp)
        XCTAssertEqual(SyncProfileConflict.merge(edited, deleted).deletedAt, stamp)
        XCTAssertEqual(SyncProfileConflict.merge(deleted, edited).deletedAt, stamp)

        var group = SyncDocumentModel()
        group.layoutProfiles = ["p1": deleted]
        var local = SyncDocumentModel()
        local.layoutProfiles = ["p1": edited]
        XCTAssertTrue(group.overlaid(with: local).layoutProfiles["p1"]?.isDeleted ?? false)
    }

    func testDeletingAndRecreatingAProfileMintsANewIdentity() {
        var identities = SyncProfileIdentities()
        let first = identities.id(ofProfile: "Small hands")
        identities.markDeleted(profile: "Small hands", at: stamp)
        XCTAssertNil(identities.knownId(ofProfile: "Small hands"))
        XCTAssertEqual(identities.deleted[first], stamp)

        let second = identities.id(ofProfile: "Small hands")
        XCTAssertNotEqual(first, second, "the old edit cannot reach the new profile")
    }

    func testAConflictProfileCarriesTheStatedNameAndOneIdentity() {
        let losing = SyncProfile(
            name: "Small hands", controls: ["portrait.dpad": .string("{\"x\":0.2}")])
        let rebuilt = SyncProfileConflict.conflictProfile(
            id: "p1", losing: losing, deviceName: "iPad")
        XCTAssertEqual(rebuilt.profile.name, "Small hands from iPad")
        XCTAssertEqual(rebuilt.profile.controls, losing.controls)
        XCTAssertNotNil(rebuilt.profile.origin)

        // Both devices meet the same conflict, so both mint the same
        // identity and the document holds one conflict profile.
        let other = SyncProfileConflict.conflictProfile(
            id: "p1", losing: losing, deviceName: "iPhone")
        XCTAssertEqual(rebuilt.id, other.id)
        XCTAssertNotEqual(
            rebuilt.id,
            SyncProfileConflict.makeId(profileId: "p2", losing: losing.controls))
        XCTAssertNotEqual(
            rebuilt.id,
            SyncProfileConflict.makeId(
                profileId: "p1", losing: ["portrait.dpad": .string("{\"x\":0.9}")]))
    }

    func testNoRuleReadsTheClock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/GameProbe/Backup/Sync")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var read = 0
        for name in names where name.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            read += 1
            // A winner never comes from wall time, per 10.6. The
            // deletion record of 10.9 is the one date rule, and it
            // takes its date from the caller.
            XCTAssertFalse(text.contains("Date()"), name)
        }
        XCTAssertGreaterThan(read, 5)
    }

    // MARK: - 10.7

    func testTheLocalFolderMovesAsideWholeOnANameCollision() {
        XCTAssertEqual(
            DisplacedCopy.nextTreeName(for: "Small hands", taken: ["Small hands"]),
            "Small hands.empo-displaced")
        XCTAssertEqual(
            DisplacedCopy.nextTreeName(
                for: "Small hands", taken: ["Small hands", "Small hands.empo-displaced"]),
            "Small hands.empo-displaced-2")
    }

    func testAProfileTravelsAsItIsThroughTheControlIds() {
        let section = TouchSection(
            portrait: TouchLayout(
                dpad: DPadSpec(x: 0.2, y: 0.8, size: 0.3, opacity: 0.9),
                buttons: [
                    ButtonSpec(label: "A", key: "KeyZ", x: 0.8, y: 0.8),
                    ButtonSpec(label: "B", key: "KeyZ", x: 0.6, y: 0.8),
                ],
                actionButtons: []),
            landscape: nil)
        let controls = TouchSectionSyncCoder.controls(of: section)
        XCTAssertEqual(
            Set(controls.keys), ["portrait.dpad", "portrait.key.KeyZ", "portrait.key.KeyZ#2"])
        XCTAssertEqual(TouchSectionSyncCoder.section(of: controls).portrait?.buttons?.count, 2)
        XCTAssertEqual(TouchSectionSyncCoder.section(of: controls).landscape, nil)
    }

    func testEachGlobalBindingTakesItsOwnLeaf() {
        let map = BindingMap(entries: [.key("KeyZ"): .key("KeyX")])
        let entries = BindingMapSyncCoder.entries(of: map)
        XCTAssertEqual(entries["KeyZ"], .string("KeyX"))
        XCTAssertEqual(BindingMapSyncCoder.map(of: entries), map)
        XCTAssertEqual(BindingMapSyncCoder.map(of: ["nothing at all": .string("KeyX")]).entries, [:])
    }

    // MARK: - 10.8

    func testADescriptorTravelsWithNoSecretAndNoAccountHint() {
        let descriptor = TargetDescriptor(
            id: "t1", provider: .dropbox, label: "Dropbox", accountHint: "me@example.com",
            root: "Apps/Empo", sizeThresholdBytes: 500, capBytes: 900, isPaused: true)
        let shared = descriptor.forSyncDocument()
        XCTAssertNil(shared.accountHint)
        XCTAssertEqual(shared.id, "t1")
        XCTAssertEqual(shared.provider, .dropbox)
        XCTAssertEqual(shared.label, "Dropbox")
        XCTAssertEqual(shared.root, "Apps/Empo")
        XCTAssertEqual(shared.sizeThresholdBytes, 500)
        XCTAssertEqual(shared.capBytes, 900)
        XCTAssertTrue(shared.isPaused)
    }

    // MARK: - 10.9

    func testARollbackWritesTheSnapshotAndClearsWhatItDropped() {
        let current: [String: JSONValue] = [
            "theme": .string("dark"), "titlePosition": .string("below"), "debugMode": .bool(true),
        ]
        let snapshot: [String: JSONValue] = ["theme": .string("light")]
        let plan = PreferenceRollback.plan(current: current, snapshot: snapshot)
        XCTAssertEqual(plan.sets, ["theme": .string("light")])
        XCTAssertEqual(plan.deletes, ["titlePosition"])
        XCTAssertFalse(plan.isEmpty)
        XCTAssertTrue(
            PreferenceRollback.plan(current: snapshot, snapshot: snapshot).isEmpty,
            "the same values write nothing")
    }

    func testTheUndoExpiresAtSevenDaysAndNotAtSix() {
        let undo = PreferenceRollbackUndo(savedAt: stamp, values: ["theme": .string("dark")])
        let day: TimeInterval = 24 * 60 * 60
        XCTAssertFalse(undo.isExpired(at: stamp.addingTimeInterval(6 * day)))
        XCTAssertFalse(undo.isExpired(at: stamp.addingTimeInterval(7 * day)))
        XCTAssertTrue(undo.isExpired(at: stamp.addingTimeInterval(7 * day + 1)))
    }

    func testTheUndoFileGoesAndComesBackAndAnExpiredOneIsDropped() throws {
        let support = try temporaryDirectory()
        XCTAssertNil(PreferenceRollbackUndo.read(applicationSupport: support, at: stamp))

        let undo = PreferenceRollbackUndo(savedAt: stamp, values: ["theme": .string("dark")])
        try undo.write(applicationSupport: support)
        XCTAssertEqual(
            PreferenceRollbackUndo.read(applicationSupport: support, at: stamp)?.values,
            undo.values)

        let late = stamp.addingTimeInterval(8 * 24 * 60 * 60)
        XCTAssertNil(PreferenceRollbackUndo.read(applicationSupport: support, at: late))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: BackupRootLayout.preferenceRollbackFile(applicationSupport: support).path),
            "reading an expired undo drops it")
    }

    // MARK: - 10.10

    func testABuildStopsPublishingToADocumentItCannotWrite() {
        XCTAssertTrue(SyncSchema.canPublish(toDocumentRequiring: SyncSchema.writerVersion))
        XCTAssertFalse(SyncSchema.canPublish(toDocumentRequiring: SyncSchema.writerVersion + 1))

        var newer = SyncDocumentModel()
        newer.minimumWriterVersion = SyncSchema.writerVersion + 1
        newer.preferences = ["theme": .string("dark")]
        XCTAssertTrue(SyncCopyValidation.readsButDoesNotPublish(newer))
        XCTAssertEqual(
            newer.preferences["theme"], .string("dark"),
            "it still reads the fields it knows")

        let rejection = SyncCopyValidation.check(Data([1])) { _ in newer }.failure
        XCTAssertEqual(
            rejection, .unsupported(minimumWriterVersion: SyncSchema.writerVersion + 1))
    }

    // MARK: - The state file

    func testTheStateFileKeepsTheActorAndTheProgress() throws {
        let support = try temporaryDirectory()
        var state = SyncState.read(applicationSupport: support, actorId: "actor-1")
        XCTAssertEqual(state.actorId, "actor-1")
        XCTAssertFalse(state.hasJoined)

        state.startAGroup(at: stamp)
        state.confirm(targetId: "t1", heads: ["aa"])
        state.saw(namespaceId: "ns-1", at: stamp, targetId: "t1")
        try state.write(applicationSupport: support)

        let read = SyncState.read(applicationSupport: support, actorId: "actor-2")
        XCTAssertEqual(read.actorId, "actor-1")
        XCTAssertEqual(read.groupId, state.groupId)
        XCTAssertEqual(read.progress(ofTarget: "t1")?.confirmedHeads, ["aa"])
        XCTAssertEqual(read.progress(ofTarget: "t1")?.seenNamespaces["ns-1"], stamp)

        var forgotten = read
        forgotten.forget(targetId: "t1")
        XCTAssertTrue(forgotten.targets.isEmpty)
    }

    func testTheIdentityFileKeepsTheNamesAndTheDeletions() throws {
        let support = try temporaryDirectory()
        var identities = SyncProfileIdentities.read(applicationSupport: support)
        let id = identities.id(ofProfile: "Small hands")
        identities.rename(from: "Small hands", to: "Small hands 2")
        try identities.write(applicationSupport: support)

        let read = SyncProfileIdentities.read(applicationSupport: support)
        XCTAssertEqual(read.knownId(ofProfile: "Small hands 2"), id)
        XCTAssertEqual(read.name(ofId: id), "Small hands 2")
        XCTAssertNil(read.knownId(ofProfile: "Small hands"))
    }

    // MARK: - Fixtures

    private func record(name: String, group: String?) -> DeviceRecord {
        DeviceRecord(
            deviceId: name, model: "iPhone", name: name, lastWriteAt: stamp,
            syncGroupId: group.map { $0.repeated(32) },
            syncUpdatedAt: stamp)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

extension String {
    fileprivate func repeated(_ count: Int) -> String {
        String(String(repeating: self, count: count).prefix(count))
    }
}

extension Result where Failure == SyncCopyRejection {
    fileprivate var failure: SyncCopyRejection? {
        guard case .failure(let rejection) = self else { return nil }
        return rejection
    }
}

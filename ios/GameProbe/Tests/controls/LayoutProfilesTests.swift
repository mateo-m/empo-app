// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import XCTest

@testable import GameProbe

final class LayoutProfilesTests: XCTestCase {

    private var root: URL!
    private var profilesRoot: URL!
    private var gamesRoot: URL!
    private var store: LayoutProfileStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LayoutProfilesTests-\(UUID().uuidString)")
        profilesRoot = root.appendingPathComponent("Profiles")
        gamesRoot = root.appendingPathComponent("Games")
        try FileManager.default.createDirectory(
            at: profilesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gamesRoot, withIntermediateDirectories: true)
        store = LayoutProfileStore(profilesRoot: profilesRoot, gamesRoot: gamesRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func sampleTouch(buttonX: Double = 0.75) -> TouchSection {
        let layout = TouchLayout(
            dpad: DPadSpec(x: 0.25, y: 0.75, size: 140, opacity: 1),
            buttons: [ButtonSpec(label: "OK", key: "Enter", x: buttonX, y: 0.5, size: 56, opacity: 1)],
            actionButtons: []
        )
        return TouchSection(portrait: layout, landscape: layout)
    }

    private func builtins() -> ProfileMaterializer.Builtins {
        ProfileMaterializer.Builtins(keys: [BuiltinLayout.Key(label: "A", code: "Enter")])
    }

    @discardableResult
    private func makeGame(_ name: String, pin: LayoutPin?) throws -> URL {
        let folder = gamesRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("EmpoState"), withIntermediateDirectories: true)
        if let pin {
            try store.writePin(pin, forGameFolder: folder)
        }
        return folder
    }

    // MARK: - Pin file

    func testPinFileStates() throws {
        let cases: [(LayoutPin, String?)] = [
            (.followChain, nil),
            (.profile("Lefty"), "Lefty"),
            (.gameLayout, "$game"),
            (.defaultProfile, "$default"),
        ]
        for (pin, _) in cases {
            let data = try LayoutPinFile.serialize(pin)
            let parsed = LayoutPinFile.parse(data: data)
            XCTAssertEqual(parsed.pin, pin)
            XCTAssertNil(parsed.note)
        }
        // Explicit followChain still writes a file with version 1,
        // distinguishable from "no file".
        XCTAssertTrue(
            String(data: try LayoutPinFile.serialize(.followChain), encoding: .utf8)!
                .contains("\"version\":1"))
    }

    func testPinFileUnknownStates() {
        let unknownVersion = Data(#"{"version":2,"pin":"Lefty"}"#.utf8)
        let v2 = LayoutPinFile.parse(data: unknownVersion)
        XCTAssertEqual(v2.pin, .followChain)
        XCTAssertNotNil(v2.note)

        let unknownSentinel = Data(#"{"version":1,"pin":"$mystery"}"#.utf8)
        let sentinel = LayoutPinFile.parse(data: unknownSentinel)
        XCTAssertEqual(sentinel.pin, .followChain)
        XCTAssertNotNil(sentinel.note)

        let garbage = LayoutPinFile.parse(data: Data("not json".utf8))
        XCTAssertEqual(garbage.pin, .followChain)
        XCTAssertNotNil(garbage.note)
    }

    func testPinFileRejectsNamesThatFailProfileValidation() throws {
        for bad in ["..", "../Escape", "a/b", "a\\b", ".hidden", " ", ""] {
            let data = try! JSONSerialization.data(
                withJSONObject: ["version": 1, "pin": bad])
            let parsed = LayoutPinFile.parse(data: data)
            XCTAssertEqual(parsed.pin, .followChain, "pin \(bad) must not resolve")
            XCTAssertNotNil(parsed.note, "pin \(bad) must leave a note")
        }
    }

    // MARK: - Chain resolver

    func testChainResolverMatrix() {
        typealias Levels = LayoutChainResolver.Levels

        // Named pin wins when valid.
        XCTAssertEqual(
            LayoutChainResolver.resolve(
                pin: .profile("P"),
                levels: Levels(
                    pinnedProfile: ("P", true), gameLayoutOccupied: true, defaultProfile: ("D", true))),
            LayoutChainResolver.Outcome(provenance: .pinnedProfile("P"), fellThrough: false))

        // Missing named pin resumes the chain at the game level.
        XCTAssertEqual(
            LayoutChainResolver.resolve(
                pin: .profile("P"),
                levels: Levels(
                    pinnedProfile: ("P", false), gameLayoutOccupied: true, defaultProfile: ("D", true))),
            LayoutChainResolver.Outcome(provenance: .gameLayout, fellThrough: true))
        XCTAssertEqual(
            LayoutChainResolver.resolve(
                pin: .profile("P"),
                levels: Levels(
                    pinnedProfile: ("P", false), gameLayoutOccupied: false, defaultProfile: ("D", true))),
            LayoutChainResolver.Outcome(provenance: .defaultProfile("D"), fellThrough: true))

        // $game forces the game level. Its fallback skips the
        // default profile on purpose.
        XCTAssertEqual(
            LayoutChainResolver.resolve(
                pin: .gameLayout,
                levels: Levels(
                    pinnedProfile: nil, gameLayoutOccupied: false, defaultProfile: ("D", true))),
            LayoutChainResolver.Outcome(provenance: .builtin, fellThrough: true))

        // $default falls to builtin when unset.
        XCTAssertEqual(
            LayoutChainResolver.resolve(
                pin: .defaultProfile,
                levels: Levels(
                    pinnedProfile: nil, gameLayoutOccupied: true, defaultProfile: nil)),
            LayoutChainResolver.Outcome(provenance: .builtin, fellThrough: true))

        // Follow-chain ordering: game, default, builtin.
        XCTAssertEqual(
            LayoutChainResolver.resolve(
                pin: .followChain,
                levels: Levels(
                    pinnedProfile: nil, gameLayoutOccupied: true, defaultProfile: ("D", true))),
            LayoutChainResolver.Outcome(provenance: .gameLayout, fellThrough: false))
        XCTAssertEqual(
            LayoutChainResolver.resolve(
                pin: .followChain,
                levels: Levels(
                    pinnedProfile: nil, gameLayoutOccupied: false, defaultProfile: ("D", true))),
            LayoutChainResolver.Outcome(provenance: .defaultProfile("D"), fellThrough: false))
        XCTAssertEqual(
            LayoutChainResolver.resolve(
                pin: .followChain,
                levels: Levels(
                    pinnedProfile: nil, gameLayoutOccupied: false, defaultProfile: nil)),
            LayoutChainResolver.Outcome(provenance: .builtin, fellThrough: false))
    }

    // MARK: - Name validation

    func testANameThatLeavesTheProfilesFolderTouchesNothing() throws {
        let fm = FileManager.default
        XCTAssertThrowsError(try store.writeProfile("..", touch: sampleTouch()))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("controls.json").path))
        XCTAssertThrowsError(try store.writeProfile("a/../../Games", touch: sampleTouch()))
        XCTAssertFalse(fm.fileExists(atPath: gamesRoot.appendingPathComponent("controls.json").path))

        try store.createProfile("Kept", touch: sampleTouch())
        XCTAssertThrowsError(try store.deleteProfile(".."))
        XCTAssertThrowsError(try store.deleteProfile("."))
        XCTAssertThrowsError(try store.deleteProfile(""))
        XCTAssertTrue(fm.fileExists(atPath: gamesRoot.path))
        XCTAssertTrue(store.profileExists("Kept"))
    }

    func testNameValidation() {
        XCTAssertEqual(LayoutProfileStore.validatedName("  Lefty  "), "Lefty")
        XCTAssertNil(LayoutProfileStore.validatedName(""))
        XCTAssertNil(LayoutProfileStore.validatedName("   "))
        XCTAssertNil(LayoutProfileStore.validatedName("$game"))
        XCTAssertNil(LayoutProfileStore.validatedName("$anything"))
        XCTAssertNil(LayoutProfileStore.validatedName(".hidden"))
        XCTAssertNil(LayoutProfileStore.validatedName("a/b"))
        XCTAssertNil(LayoutProfileStore.validatedName(".."))
        // NFC normalization: the decomposed form maps to the same
        // name as the precomposed form.
        let nfd = "Cafe\u{0301}"
        let nfc = "Café"
        XCTAssertEqual(LayoutProfileStore.validatedName(nfd), nfc)
    }

    // MARK: - Store round trips

    func testCreateListReadRoundTrip() throws {
        try store.createProfile("Lefty", touch: sampleTouch())
        XCTAssertThrowsError(try store.createProfile("Lefty", touch: sampleTouch()), "no overwrite") {
            XCTAssertEqual($0 as? LayoutProfileStore.StoreError, .nameTaken("Lefty"))
        }
        XCTAssertEqual(store.listProfiles(), ["Lefty"])
        let read = store.readProfile("Lefty")
        XCTAssertEqual(read?.errors.isEmpty, true)
        XCTAssertNotNil(read?.touch?.portrait)
        XCTAssertNotNil(read?.touch?.landscape)
    }

    func testUniqueName() throws {
        try store.createProfile("Firered", touch: sampleTouch())
        XCTAssertEqual(store.uniqueName(base: "Firered"), "Firered 2")
        try store.createProfile("Firered 2", touch: sampleTouch())
        XCTAssertEqual(store.uniqueName(base: "Firered"), "Firered 3")
        XCTAssertEqual(store.uniqueName(base: "$bad"), "Layout")
        XCTAssertEqual(store.uniqueName(base: "firered"), "firered 3", "case-insensitive disk")
    }

    func testRenameWalksPins() throws {
        try store.createProfile("Old", touch: sampleTouch())
        let gameA = try makeGame("A", pin: .profile("Old"))
        let gameB = try makeGame("B", pin: .gameLayout)

        try store.renameProfile(from: "Old", to: "New")
        XCTAssertEqual(store.listProfiles(), ["New"])
        XCTAssertEqual(store.loadPin(forGameFolder: gameA).pin, .profile("New"))
        XCTAssertEqual(store.loadPin(forGameFolder: gameB).pin, .gameLayout, "untouched")
        XCTAssertThrowsError(try store.renameProfile(from: "New", to: "$game"), "sentinel rejected")
    }

    func testAFailedCreateKeepsWhatWasThereBefore() throws {
        let file = profilesRoot.appendingPathComponent("Keep")
        try Data("mine".utf8).write(to: file)

        XCTAssertThrowsError(try store.createProfile("Keep", touch: sampleTouch()))
        XCTAssertEqual(try Data(contentsOf: file), Data("mine".utf8))
    }

    func testANewProfileTakesItsOwnCaseOverAnEmptyFolder() throws {
        try FileManager.default.createDirectory(
            at: profilesRoot.appendingPathComponent("Foo"), withIntermediateDirectories: true)

        try store.createProfile("foo", touch: sampleTouch())
        XCTAssertEqual(store.listProfiles(), ["foo"])
        XCTAssertNotNil(store.readProfile("foo")?.touch)
    }

    func testAnEmptyFolderInAnotherCaseDoesNotHideAProfile() throws {
        let fm = FileManager.default
        try store.createProfile("Foo", touch: sampleTouch())
        let empty = profilesRoot.appendingPathComponent("FOO", isDirectory: true)
        guard !fm.fileExists(atPath: empty.path) else {
            throw XCTSkip("This disk ignores case, so it cannot hold both folders.")
        }
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.createProfile("foo", touch: sampleTouch()))
        XCTAssertEqual(store.listProfiles(), ["FOO", "Foo"])
    }

    func testARenameOfOnlyTheCaseMovesTheFolderAndThePins() throws {
        try store.createProfile("Foo", touch: sampleTouch())
        let game = try makeGame("A", pin: .profile("Foo"))

        try store.renameProfile(from: "Foo", to: "foo")
        XCTAssertEqual(store.listProfiles(), ["foo"])
        XCTAssertEqual(store.loadPin(forGameFolder: game).pin, .profile("foo"))
        XCTAssertNotNil(store.readProfile("foo")?.touch)
    }

    /// An older version let an iPhone keep "Foo" and "foo" side by side.
    func testTwoNamesThatDifferOnlyByCaseKeepTheirOwnPins() throws {
        let fm = FileManager.default
        try store.createProfile("Foo", touch: sampleTouch())
        let twin = profilesRoot.appendingPathComponent("foo", isDirectory: true)
        guard !fm.fileExists(atPath: twin.path) else {
            throw XCTSkip("This disk ignores case, so it cannot hold both folders.")
        }
        try fm.copyItem(at: store.profileURL("Foo"), to: twin)
        let gameA = try makeGame("A", pin: .profile("Foo"))
        let gameB = try makeGame("B", pin: .profile("foo"))

        try store.renameProfile(from: "Foo", to: "Bar")
        XCTAssertEqual(store.listProfiles(), ["Bar", "foo"])
        XCTAssertEqual(store.loadPin(forGameFolder: gameA).pin, .profile("Bar"))
        XCTAssertEqual(store.loadPin(forGameFolder: gameB).pin, .profile("foo"))

        try store.deleteProfile("Bar")
        XCTAssertEqual(store.listProfiles(), ["foo"])
        XCTAssertEqual(store.loadPin(forGameFolder: gameA).pin, .followChain)
        XCTAssertEqual(store.loadPin(forGameFolder: gameB).pin, .profile("foo"))
    }

    func testAFailedPinStepUndoesTheRename() throws {
        try store.createProfile("Old", touch: sampleTouch())
        let gameA = try makeGame("A", pin: .profile("Old"))
        let gameB = try makeGame("B", pin: .profile("Old"))
        let locked = gameB.appendingPathComponent("EmpoState")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        XCTAssertThrowsError(try store.renameProfile(from: "Old", to: "New"))
        XCTAssertEqual(store.listProfiles(), ["Old"])
        XCTAssertEqual(store.loadPin(forGameFolder: gameA).pin, .profile("Old"))
        XCTAssertEqual(store.loadPin(forGameFolder: gameB).pin, .profile("Old"))
    }

    func testRenameUpdatesTheMigrationRecord() throws {
        let recordURL = profilesRoot.appendingPathComponent(MigrationRecord.fileName)
        try MigrationRecord(
            games: [
                "a": .init(hash: "1", profile: "Old"),
                "b": .init(hash: "2", profile: "Other"),
            ],
            sharedProfiles: ["Old"]
        ).save(to: recordURL)
        try store.createProfile("Old", touch: sampleTouch())

        try store.renameProfile(from: "Old", to: "New")

        XCTAssertEqual(
            MigrationRecord.load(at: recordURL),
            MigrationRecord(
                games: [
                    "a": .init(hash: "1", profile: "New"),
                    "b": .init(hash: "2", profile: "Other"),
                ],
                sharedProfiles: ["New"]))
    }

    func testRenameWritesNoMigrationRecordWhenNoneExists() throws {
        try store.createProfile("Old", touch: sampleTouch())
        try store.renameProfile(from: "Old", to: "New")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: profilesRoot.appendingPathComponent(MigrationRecord.fileName).path))
    }

    func testDeleteClearsPins() throws {
        try store.createProfile("Doomed", touch: sampleTouch())
        let game = try makeGame("A", pin: .profile("Doomed"))
        try store.deleteProfile("Doomed")
        XCTAssertEqual(store.listProfiles(), [])
        XCTAssertEqual(store.loadPin(forGameFolder: game).pin, .followChain)
    }

    func testDuplicate() throws {
        try store.createProfile("Base", touch: sampleTouch())
        XCTAssertEqual(try store.duplicateProfile("Base"), "Base 2")
        XCTAssertEqual(store.listProfiles(), ["Base", "Base 2"])
    }

    func testInvalidProfileReadLogsAndFlags() throws {
        let url = store.controlsURL("Broken")
        try FileManager.default.createDirectory(
            at: store.profileURL("Broken"), withIntermediateDirectories: true)
        try Data(#"{"version":1,"touch":{"portrait":{"dpad":{"x":9,"y":0.5}}}}"#.utf8)
            .write(to: url)
        let read = try XCTUnwrap(store.readProfile("Broken"))
        XCTAssertNil(read.touch)
        XCTAssertFalse(read.errors.isEmpty)
        store.logProblems("Broken", read: read)
        let log = store.profileURL("Broken").appendingPathComponent("controls.json.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
    }

    func testWritePreservesHandAddedControllerSection() throws {
        try store.createProfile("Keep", touch: sampleTouch())
        // Hand-add a controller section, as a Files-app user might.
        let manifest = try XCTUnwrap(
            ControlsManifestLoader.parse(data: Data(contentsOf: store.controlsURL("Keep")))
                .manifest)
        let withController = ControlsManifestSerializer.serialize(
            touch: manifest.touch,
            bindings: BindingMap(entries: [.element("y"): .key("F5")])
        )
        try XCTUnwrap(withController).write(to: store.controlsURL("Keep"))

        // A profile save must carry the section through.
        try store.writeProfile("Keep", touch: sampleTouch(buttonX: 0.5))
        let reread = ControlsManifestLoader.parse(
            data: try Data(contentsOf: store.controlsURL("Keep")))
        XCTAssertEqual(reread.manifest?.bindings?.entries[.element("y")], .key("F5"))
        XCTAssertEqual(reread.manifest?.touch?.portrait?.buttons?.first?.x, 0.5)
    }

    // MARK: - Materializer

    func testMaterializeLayersUserOverManifestOverBuiltin() {
        let manifest = TouchSection(
            portrait: TouchLayout(
                dpad: DPadSpec(x: 0.2, y: 0.7),
                buttons: nil,
                actionButtons: [ActionButtonSpec(action: "$pauseMenu", x: 0.5, y: 0.5)]
            ),
            landscape: nil
        )
        let user = TouchSection(
            portrait: TouchLayout(dpad: DPadSpec(x: 0.3, y: 0.6), buttons: nil, actionButtons: nil),
            landscape: nil
        )
        let result = ProfileMaterializer.materialize(
            user: user, manifest: manifest, builtins: builtins(), metrics: .reference)

        // User dpad wins. Buttons fall to the builtin (manifest has
        // none either). actionButtons fall to the manifest.
        XCTAssertEqual(result.portrait.dpad?.x, 0.3)
        XCTAssertEqual(result.portrait.buttons?.first?.key, "Enter")
        XCTAssertEqual(result.portrait.actionButtons?.first?.action, "$pauseMenu")
        // Both orientations always present, all fields present.
        XCTAssertNotNil(result.landscape.dpad)
        XCTAssertNotNil(result.landscape.buttons)
        XCTAssertNotNil(result.landscape.actionButtons)
    }

    func testProfileGapsCompleteAgainstBuiltinOnly() {
        // A sparse profile must not inherit from a game manifest:
        // materializing FOR a profile passes manifest: nil.
        let sparse = TouchSection(
            portrait: TouchLayout(dpad: DPadSpec(x: 0.3, y: 0.6), buttons: nil, actionButtons: nil),
            landscape: nil
        )
        let result = ProfileMaterializer.materialize(
            user: sparse, manifest: nil, builtins: builtins(), metrics: .reference)
        XCTAssertEqual(result.portrait.buttons?.first?.label, "A", "builtin, not any manifest")
        XCTAssertEqual(result.portrait.actionButtons, [])
    }

    // MARK: - Migration decisions

    private func decide(
        userTouch: TouchSection?,
        manifestTouch: TouchSection? = nil,
        pinFileExists: Bool = false,
        record: MigrationRecord = MigrationRecord(),
        gameID: String = "game-a",
        title: String = "Firered"
    ) -> ProfileMigration.Action {
        ProfileMigration.decide(
            context: ProfileMigration.Context(
                gameID: gameID,
                gameTitle: title,
                userTouch: userTouch,
                manifestTouch: manifestTouch,
                pinFileExists: pinFileExists,
                record: record,
                existingProfiles: store.listProfiles(),
                profileCanonicalBytes: { name in
                    guard let touch = self.store.readProfile(name)?.touch else { return nil }
                    return ProfileMaterializer.canonicalBytes(
                        ProfileMaterializer.materialize(
                            user: touch, manifest: nil, builtins: self.builtins(),
                            metrics: .reference))
                },
                profileHasScreen: { name in
                    FileManager.default.fileExists(atPath: self.store.screenURL(name).path)
                }
            ),
            builtins: builtins(),
            metrics: .reference
        )
    }

    private func materializedSample() -> TouchSection {
        ProfileMaterializer.materialize(
            user: sampleTouch(), manifest: nil, builtins: builtins(), metrics: .reference
        ).section
    }

    func testMigrationCreatesForFreshCustomLayout() {
        let action = decide(userTouch: sampleTouch())
        guard case .createAndPin(let base, _) = action else {
            return XCTFail("\(action)")
        }
        XCTAssertEqual(base, "Firered")
    }

    func testMigrationIsIdempotent() {
        guard case .createAndPin(_, let hash) = decide(userTouch: sampleTouch()) else {
            return XCTFail("expected create")
        }
        let record = MigrationRecord(games: [
            "game-a": MigrationRecord.Entry(hash: hash, profile: "Firered")
        ])
        XCTAssertEqual(decide(userTouch: sampleTouch(), record: record), .none)
    }

    func testMigrationOffersImportWhenContentChanged() {
        let record = MigrationRecord(games: [
            "game-a": MigrationRecord.Entry(hash: "0000000000000000", profile: "Firered")
        ])
        XCTAssertEqual(decide(userTouch: sampleTouch(), record: record), .importOffer)
    }

    func testMigrationKeepsRecordWhenSectionRemoved() {
        let record = MigrationRecord(games: [
            "game-a": MigrationRecord.Entry(hash: "0000000000000000", profile: "Firered")
        ])
        XCTAssertEqual(decide(userTouch: nil, record: record), .none)
    }

    func testMigrationRecordsOnlyForAmbientEqualLayout() {
        // A layout identical to the ambient default carries no user
        // intent: no profile.
        let ambient = ProfileMaterializer.materialize(
            user: nil, manifest: nil, builtins: builtins(), metrics: .reference)
        let action = decide(userTouch: ambient.section)
        guard case .recordOnly = action else { return XCTFail("\(action)") }
    }

    func testMigrationRespectsExistingPinFile() {
        let action = decide(userTouch: sampleTouch(), pinFileExists: true)
        guard case .recordOnly = action else { return XCTFail("\(action)") }
    }

    func testMigrationDedupesIntoSharedProfile() throws {
        // Game A's migration created "Firered" with identical content.
        try store.createProfile("Firered", touch: materializedSample())
        let record = MigrationRecord(games: [
            "game-a": MigrationRecord.Entry(hash: "irrelevant", profile: "Firered")
        ])
        let action = decide(
            userTouch: sampleTouch(), record: record, gameID: "game-b", title: "Clone")
        guard case .pinToExisting(let profile, let renameToShared, _) = action else {
            return XCTFail("\(action)")
        }
        XCTAssertEqual(profile, "Firered")
        XCTAssertTrue(renameToShared)
    }

    func testMigrationKeepsSharedProfileNameAfterOneGameLeaves() throws {
        // Games A and B shared "Disposition partagée", then A took a
        // new layout, so only B's record names the profile.
        try store.createProfile("Disposition partagée", touch: materializedSample())
        let record = MigrationRecord(
            games: [
                "game-a": MigrationRecord.Entry(hash: "irrelevant", profile: "Game A"),
                "game-b": MigrationRecord.Entry(hash: "irrelevant", profile: "Disposition partagée"),
            ],
            sharedProfiles: ["Disposition partagée"])
        let action = decide(
            userTouch: sampleTouch(), record: record, gameID: "game-c", title: "Clone")
        guard case .pinToExisting(let profile, let renameToShared, _) = action else {
            return XCTFail("\(action)")
        }
        XCTAssertEqual(profile, "Disposition partagée")
        XCTAssertFalse(renameToShared)
    }

    func testMigrationRecordReadsOlderSharedProfilesFromTheirNames() {
        let data = Data(
            """
            {"version":1,"games":{"a":{"hash":"x","profile":"Shared layout 2"},"b":{"hash":"y","profile":"Firered"}}}
            """.utf8)
        XCTAssertEqual(MigrationRecord.parse(data: data)?.sharedProfiles, ["Shared layout 2"])
    }

    func testMigrationRecordKeepsSharedProfilesThroughSave() throws {
        let record = MigrationRecord(
            games: ["a": MigrationRecord.Entry(hash: "x", profile: "Firered")],
            sharedProfiles: ["Firered"])
        XCTAssertEqual(MigrationRecord.parse(data: try record.serialize()), record)
    }

    func testMigrationMatchesUserProfileWithoutSharedRename() throws {
        // A hand-made profile with identical content: pin to it, but
        // never rename a profile the user named.
        try store.createProfile("My Layout", touch: materializedSample())
        let action = decide(userTouch: sampleTouch(), gameID: "game-b", title: "Clone")
        guard case .pinToExisting(let profile, let renameToShared, _) = action else {
            return XCTFail("\(action)")
        }
        XCTAssertEqual(profile, "My Layout")
        XCTAssertFalse(renameToShared)
    }

    func testMigrationRecordRoundTrip() throws {
        let record = MigrationRecord(games: [
            "a": MigrationRecord.Entry(hash: "abc", profile: "P"),
            "b": MigrationRecord.Entry(hash: "def", profile: nil),
        ])
        XCTAssertEqual(MigrationRecord.parse(data: try record.serialize()), record)
        XCTAssertNil(MigrationRecord.parse(data: Data("junk".utf8)))
    }

    // MARK: - Off-player resolution

    func testLayoutResolutionProvenance() throws {
        try store.createProfile("Lefty", touch: sampleTouch())
        func resolve(_ folder: URL, defaultProfileName: String?) -> LayoutChainResolver.Outcome {
            LayoutResolution.resolve(
                pin: store.loadPin(forGameFolder: folder).pin, gameRoot: folder, store: store,
                defaultProfileName: defaultProfileName, metrics: .reference)
        }
        let pinned = try makeGame("A", pin: .profile("Lefty"))
        XCTAssertEqual(
            resolve(pinned, defaultProfileName: nil),
            LayoutChainResolver.Outcome(provenance: .pinnedProfile("Lefty"), fellThrough: false))

        let dangling = try makeGame("B", pin: .profile("Gone"))
        XCTAssertEqual(
            resolve(dangling, defaultProfileName: "Lefty"),
            LayoutChainResolver.Outcome(provenance: .defaultProfile("Lefty"), fellThrough: true))

        let plain = try makeGame("C", pin: nil)
        XCTAssertEqual(
            resolve(plain, defaultProfileName: nil),
            LayoutChainResolver.Outcome(provenance: .builtin, fellThrough: false))
    }

    func testProfileFileRoundTripIsByteStable() throws {
        // A profile the app wrote re-saves byte-identically: the
        // materializer/serializer pair is a fixpoint once concrete.
        try store.createProfile("Stable", touch: materializedSample())
        let first = try Data(contentsOf: store.controlsURL("Stable"))
        let reread = try XCTUnwrap(store.readProfile("Stable")?.touch)
        let rematerialized = ProfileMaterializer.materialize(
            user: reread, manifest: nil, builtins: builtins(), metrics: .reference)
        try store.writeProfile("Stable", touch: rematerialized.section)
        let second = try Data(contentsOf: store.controlsURL("Stable"))
        XCTAssertEqual(first, second)
    }

    func testFNV1aIsStable() {
        XCTAssertEqual(FNV1a.hash64(Data()), "cbf29ce484222325")
        XCTAssertEqual(FNV1a.hash64(Data("a".utf8)), "af63dc4c8601ec8c")
    }

    func testNamesThatDifferOnlyByCaseNameOneProfile() throws {
        try store.createProfile("Firered", touch: sampleTouch())
        let game = try makeGame("Game", pin: .profile("firered"))
        XCTAssertTrue(store.profileExists("FIRERED"))
        XCTAssertEqual(store.storedName("firered"), "Firered")
        XCTAssertNotNil(store.validTouch("firered"))
        XCTAssertEqual(store.gamesPinned(to: "Firered").map(\.lastPathComponent), ["Game"])
        XCTAssertThrowsError(try store.createProfile("FireRed", touch: sampleTouch()))

        try store.renameProfile(from: "firered", to: "Leafgreen")
        XCTAssertEqual(store.listProfiles(), ["Leafgreen"])
        XCTAssertEqual(store.loadPin(forGameFolder: game).pin, .profile("Leafgreen"))
    }

    func testFailedPinMoveUndoesTheRename() throws {
        try XCTSkipIf(getuid() == 0, "root ignores file permissions")
        try store.createProfile("Old", touch: sampleTouch())
        let game = try makeGame("Game", pin: .profile("Old"))
        let stateDir = game.appendingPathComponent("EmpoState")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateDir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: stateDir.path)
        }
        XCTAssertThrowsError(try store.renameProfile(from: "Old", to: "New"))
        XCTAssertEqual(store.listProfiles(), ["Old"])
        XCTAssertEqual(store.loadPin(forGameFolder: game).pin, .profile("Old"))
    }

    func testUnreadableMigrationRecordLoadsAsNil() throws {
        let url = profilesRoot.appendingPathComponent(MigrationRecord.fileName)
        XCTAssertEqual(MigrationRecord.load(at: url), MigrationRecord())
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(MigrationRecord.load(at: url))
        try Data(#"{"version":2,"games":{}}"#.utf8).write(to: url)
        XCTAssertNil(MigrationRecord.load(at: url))
    }

    func testBuiltinKeyWithoutCodeKeepsTheOtherButtonsInPlace() {
        let keys = [
            BuiltinLayout.Key(label: "A", code: "Enter"),
            BuiltinLayout.Key(label: "B", code: nil),
            BuiltinLayout.Key(label: "C", code: "Escape"),
        ]
        let layout = BuiltinLayout.layout(keys: keys, isLandscape: false)
        let centers = BuiltinLayout.buttonCenters(isLandscape: false)
        XCTAssertEqual(layout.buttons?.map(\.label), ["A", "C"])
        XCTAssertEqual(layout.buttons?.last?.x, centers[2].x)
        XCTAssertEqual(layout.buttons?.last?.y, centers[2].y)
    }
}

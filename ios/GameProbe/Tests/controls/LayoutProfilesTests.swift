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
        ProfileMaterializer.Builtins(
            portrait: TouchLayout(
                dpad: DPadSpec(x: 0.13, y: 0.72, size: 140, opacity: 1),
                buttons: [
                    ButtonSpec(label: "A", key: "Enter", x: 0.7, y: 0.67, size: 56, opacity: 1)
                ],
                actionButtons: []
            ),
            landscape: TouchLayout(
                dpad: DPadSpec(x: 0.10, y: 0.65, size: 140, opacity: 1),
                buttons: [
                    ButtonSpec(label: "A", key: "Enter", x: 0.8, y: 0.59, size: 56, opacity: 1)
                ],
                actionButtons: []
            )
        )
    }

    @discardableResult
    private func makeGame(_ name: String, pin: LayoutPin?) throws -> URL {
        let folder = gamesRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("EmpoState"), withIntermediateDirectories: true)
        if let pin {
            store.writePin(pin, forGameFolder: folder)
        }
        return folder
    }

    // MARK: - Pin file

    func testPinFileStates() {
        let cases: [(LayoutPin, String?)] = [
            (.followChain, nil),
            (.profile("Lefty"), "Lefty"),
            (.gameLayout, "$game"),
            (.defaultProfile, "$default"),
        ]
        for (pin, _) in cases {
            let data = LayoutPinFile.serialize(pin)
            let parsed = LayoutPinFile.parse(data: data)
            XCTAssertEqual(parsed.pin, pin)
            XCTAssertNil(parsed.note)
        }
        // Explicit followChain still writes a file with version 1,
        // distinguishable from "no file".
        XCTAssertTrue(
            String(data: LayoutPinFile.serialize(.followChain), encoding: .utf8)!
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

    func testPinFileRejectsNamesThatFailProfileValidation() {
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

        // $game forces the game level; its fallback skips the
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

    func testCreateListReadRoundTrip() {
        XCTAssertTrue(store.createProfile("Lefty", touch: sampleTouch()))
        XCTAssertFalse(store.createProfile("Lefty", touch: sampleTouch()), "no overwrite")
        XCTAssertEqual(store.listProfiles(), ["Lefty"])
        let read = store.readProfile("Lefty")
        XCTAssertEqual(read?.invalid, false)
        XCTAssertNotNil(read?.touch?.portrait)
        XCTAssertNotNil(read?.touch?.landscape)
    }

    func testUniqueName() {
        XCTAssertTrue(store.createProfile("Firered", touch: sampleTouch()))
        XCTAssertEqual(store.uniqueName(base: "Firered"), "Firered 2")
        XCTAssertTrue(store.createProfile("Firered 2", touch: sampleTouch()))
        XCTAssertEqual(store.uniqueName(base: "Firered"), "Firered 3")
        XCTAssertEqual(store.uniqueName(base: "$bad"), "Layout")
    }

    func testRenameWalksPins() throws {
        XCTAssertTrue(store.createProfile("Old", touch: sampleTouch()))
        let gameA = try makeGame("A", pin: .profile("Old"))
        let gameB = try makeGame("B", pin: .gameLayout)

        XCTAssertTrue(store.renameProfile(from: "Old", to: "New"))
        XCTAssertEqual(store.listProfiles(), ["New"])
        XCTAssertEqual(store.loadPin(forGameFolder: gameA).pin, .profile("New"))
        XCTAssertEqual(store.loadPin(forGameFolder: gameB).pin, .gameLayout, "untouched")
        XCTAssertFalse(store.renameProfile(from: "New", to: "$game"), "sentinel rejected")
    }

    func testDeleteClearsPins() throws {
        XCTAssertTrue(store.createProfile("Doomed", touch: sampleTouch()))
        let game = try makeGame("A", pin: .profile("Doomed"))
        XCTAssertTrue(store.deleteProfile("Doomed"))
        XCTAssertEqual(store.listProfiles(), [])
        XCTAssertEqual(store.loadPin(forGameFolder: game).pin, .followChain)
    }

    func testDuplicate() {
        XCTAssertTrue(store.createProfile("Base", touch: sampleTouch()))
        XCTAssertEqual(store.duplicateProfile("Base"), "Base 2")
        XCTAssertEqual(store.listProfiles(), ["Base", "Base 2"])
    }

    func testInvalidProfileReadLogsAndFlags() throws {
        let url = store.controlsURL("Broken")
        try FileManager.default.createDirectory(
            at: store.profileURL("Broken"), withIntermediateDirectories: true)
        try Data(#"{"version":1,"touch":{"portrait":{"dpad":{"x":9,"y":0.5}}}}"#.utf8)
            .write(to: url)
        let read = store.readProfile("Broken")
        XCTAssertEqual(read?.invalid, true)
        let log = store.profileURL("Broken").appendingPathComponent("controls.json.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
    }

    func testWritePreservesHandAddedControllerSection() throws {
        XCTAssertTrue(store.createProfile("Keep", touch: sampleTouch()))
        // Hand-add a controller section, as a Files-app user might.
        let manifest = try XCTUnwrap(
            ControlsManifestLoader.parse(data: Data(contentsOf: store.controlsURL("Keep")))
                .manifest)
        let withController = ControlsManifestSerializer.serialize(
            touch: manifest.touch,
            bindings: BindingMap(entries: ["y": .key("F5")])
        )
        try XCTUnwrap(withController).write(to: store.controlsURL("Keep"))

        // A profile save must carry the section through.
        XCTAssertTrue(store.writeProfile("Keep", touch: sampleTouch(buttonX: 0.5)))
        let reread = ControlsManifestLoader.parse(
            data: try Data(contentsOf: store.controlsURL("Keep")))
        XCTAssertEqual(reread.manifest?.bindings?.entries["y"], .key("F5"))
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

        // User dpad wins; buttons fall to the builtin (manifest has
        // none either); actionButtons fall to the manifest.
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
            builtins: builtins()
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

    func testMigrationDedupesIntoSharedProfile() {
        // Game A's migration created "Firered" with identical content.
        XCTAssertTrue(store.createProfile("Firered", touch: materializedSample()))
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

    func testMigrationMatchesUserProfileWithoutSharedRename() {
        // A hand-made profile with identical content: pin to it, but
        // never rename a profile the user named.
        XCTAssertTrue(store.createProfile("My Layout", touch: materializedSample()))
        let action = decide(userTouch: sampleTouch(), gameID: "game-b", title: "Clone")
        guard case .pinToExisting(let profile, let renameToShared, _) = action else {
            return XCTFail("\(action)")
        }
        XCTAssertEqual(profile, "My Layout")
        XCTAssertFalse(renameToShared)
    }

    func testMigrationRecordRoundTrip() {
        let record = MigrationRecord(games: [
            "a": MigrationRecord.Entry(hash: "abc", profile: "P"),
            "b": MigrationRecord.Entry(hash: "def", profile: nil),
        ])
        XCTAssertEqual(MigrationRecord.parse(data: record.serialize()), record)
        XCTAssertEqual(MigrationRecord.parse(data: Data("junk".utf8)), MigrationRecord())
    }

    // MARK: - Off-player resolution

    func testLayoutResolutionProvenance() throws {
        XCTAssertTrue(store.createProfile("Lefty", touch: sampleTouch()))
        let pinned = try makeGame("A", pin: .profile("Lefty"))
        XCTAssertEqual(
            LayoutResolution.resolve(
                gameFolder: pinned, gameRoot: nil, store: store, defaultProfileName: nil),
            LayoutResolution.Result(provenance: .pinnedProfile("Lefty"), fellThrough: false))

        let dangling = try makeGame("B", pin: .profile("Gone"))
        XCTAssertEqual(
            LayoutResolution.resolve(
                gameFolder: dangling, gameRoot: nil, store: store, defaultProfileName: "Lefty"),
            LayoutResolution.Result(provenance: .defaultProfile("Lefty"), fellThrough: true))

        let plain = try makeGame("C", pin: nil)
        XCTAssertEqual(
            LayoutResolution.resolve(
                gameFolder: plain, gameRoot: nil, store: store, defaultProfileName: nil),
            LayoutResolution.Result(provenance: .builtin, fellThrough: false))
    }

    func testProfileFileRoundTripIsByteStable() throws {
        // A profile the app wrote re-saves byte-identically: the
        // materializer/serializer pair is a fixpoint once concrete.
        XCTAssertTrue(store.createProfile("Stable", touch: materializedSample()))
        let first = try Data(contentsOf: store.controlsURL("Stable"))
        let reread = try XCTUnwrap(store.readProfile("Stable")?.touch)
        let rematerialized = ProfileMaterializer.materialize(
            user: reread, manifest: nil, builtins: builtins(), metrics: .reference)
        XCTAssertTrue(store.writeProfile("Stable", touch: rematerialized.section))
        let second = try Data(contentsOf: store.controlsURL("Stable"))
        XCTAssertEqual(first, second)
    }

    func testFNV1aIsStable() {
        XCTAssertEqual(FNV1a.hash64(Data()), "cbf29ce484222325")
        XCTAssertEqual(FNV1a.hash64(Data("a".utf8)), "af63dc4c8601ec8c")
    }
}

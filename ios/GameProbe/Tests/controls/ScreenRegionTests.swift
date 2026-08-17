import Foundation
import XCTest

@testable import GameProbe

final class ScreenRegionTests: XCTestCase {

    private var root: URL!
    private var profilesRoot: URL!
    private var gamesRoot: URL!
    private var store: LayoutProfileStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScreenRegionTests-\(UUID().uuidString)")
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

    private func sampleTouch() -> TouchSection {
        let layout = TouchLayout(
            dpad: DPadSpec(x: 0.25, y: 0.75, size: 140, opacity: 1),
            buttons: [
                ButtonSpec(label: "OK", key: "Enter", x: 0.75, y: 0.5, size: 56, opacity: 1)
            ],
            actionButtons: []
        )
        return TouchSection(portrait: layout, landscape: layout)
    }

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: - Parse

    func testParseBothOrientations() {
        let result = ScreenRegionFile.parse(
            data(
                """
                {
                  "version": 1,
                  "portrait": { "x": 0, "y": 0.05, "w": 1, "h": 0.55 },
                  "landscape": { "x": 0.1, "y": 0, "w": 0.8, "h": 1 }
                }
                """))
        XCTAssertEqual(result.portrait, .region(ScreenRegion(x: 0, y: 0.05, w: 1, h: 0.55)))
        XCTAssertEqual(result.landscape, .region(ScreenRegion(x: 0.1, y: 0, w: 0.8, h: 1)))
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testParseSingleOrientation() {
        let result = ScreenRegionFile.parse(
            data(#"{ "version": 1, "landscape": { "x": 0, "y": 0, "w": 1, "h": 1 } }"#))
        XCTAssertNil(result.portrait)
        XCTAssertNotNil(result.landscape)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testParseNotAnObjectIsS001() {
        let result = ScreenRegionFile.parse(data("[1, 2]"))
        XCTAssertNil(result.portrait)
        XCTAssertNil(result.landscape)
        XCTAssertTrue(result.findings.contains { $0.hasPrefix("S001") })
    }

    func testParseGarbageIsS001() {
        let result = ScreenRegionFile.parse(data("not json"))
        XCTAssertTrue(result.findings.contains { $0.hasPrefix("S001") })
    }

    func testParseWrongVersionIsS002() {
        for json in [#"{ "portrait": {} }"#, #"{ "version": 2 }"#] {
            let result = ScreenRegionFile.parse(data(json))
            XCTAssertNil(result.portrait)
            XCTAssertTrue(result.findings.contains { $0.hasPrefix("S002") }, json)
        }
    }

    func testParseEntryNotAnObjectIsS003() {
        let result = ScreenRegionFile.parse(data(#"{ "version": 1, "portrait": 5 }"#))
        XCTAssertNil(result.portrait)
        XCTAssertTrue(result.findings.contains { $0.hasPrefix("S003") })
    }

    func testParseMissingFieldsIsS004() {
        let result = ScreenRegionFile.parse(
            data(#"{ "version": 1, "portrait": { "x": 0, "y": 0, "w": "1" } }"#))
        XCTAssertNil(result.portrait)
        XCTAssertTrue(result.findings.contains { $0.hasPrefix("S004") })
    }

    func testParseOutOfBoundsIsS005() {
        let cases = [
            #"{ "x": -0.1, "y": 0, "w": 0.5, "h": 0.5 }"#,
            #"{ "x": 0.6, "y": 0, "w": 0.5, "h": 0.5 }"#,
            #"{ "x": 0, "y": 0, "w": 0.2, "h": 0.5 }"#,
            #"{ "x": 0, "y": 0, "w": 0.5, "h": 0.1 }"#,
        ]
        for entry in cases {
            let result = ScreenRegionFile.parse(
                data(#"{ "version": 1, "portrait": "# + entry + " }"))
            XCTAssertNil(result.portrait, entry)
            XCTAssertTrue(result.findings.contains { $0.hasPrefix("S005") }, entry)
        }
    }

    func testParseInvalidEntryKeepsTheOtherOrientation() {
        let result = ScreenRegionFile.parse(
            data(
                """
                {
                  "version": 1,
                  "portrait": { "x": 0, "y": 0, "w": 0.1, "h": 0.1 },
                  "landscape": { "x": 0, "y": 0, "w": 1, "h": 1 }
                }
                """))
        XCTAssertNil(result.portrait)
        XCTAssertNotNil(result.landscape)
    }

    func testParseEpsilonAtTheBoundary() {
        // 0.3 + 0.7 can exceed 1 by floating-point noise. The
        // epsilon keeps the entry valid.
        let result = ScreenRegionFile.parse(
            data(#"{ "version": 1, "portrait": { "x": 0.3, "y": 0, "w": 0.7, "h": 1 } }"#))
        XCTAssertNotNil(result.portrait)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testParseUnknownKeyIsWS1AndDropsOnRewrite() throws {
        let result = ScreenRegionFile.parse(
            data(#"{ "version": 1, "zoom": 2, "portrait": { "x": 0, "y": 0, "w": 1, "h": 1 } }"#))
        XCTAssertNotNil(result.portrait)
        XCTAssertTrue(result.findings.contains { $0.hasPrefix("W-S1") })

        let rewritten = try XCTUnwrap(
            ScreenRegionFile.serialize(portrait: result.portrait, landscape: result.landscape))
        XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains("zoom"))
    }

    func testParseRejectsBooleanAndStringNumbers() {
        // JSON booleans bridge to Int/Double via NSNumber on both
        // platforms. The objCType guard must reject them.
        for json in [#"{ "version": true }"#, #"{ "version": "1" }"#] {
            let result = ScreenRegionFile.parse(data(json))
            XCTAssertTrue(result.findings.contains { $0.hasPrefix("S002") }, json)
        }
        let result = ScreenRegionFile.parse(
            data(#"{ "version": 1, "portrait": { "x": true, "y": 0, "w": 1, "h": 1 } }"#))
        XCTAssertNil(result.portrait)
        XCTAssertTrue(result.findings.contains { $0.hasPrefix("S004") })
    }

    func testOverlayFlagRoundTrips() throws {
        let result = ScreenRegionFile.parse(
            data(
                #"{ "version": 1, "portrait": { "x": 0, "y": 0.5, "w": 1, "h": 0.5, "overlay": true } }"#
            ))
        let placement = try XCTUnwrap(result.portrait)
        XCTAssertTrue(placement.overlay)

        let serialized = try XCTUnwrap(
            ScreenRegionFile.serialize(portrait: placement, landscape: nil))
        let reparsed = ScreenRegionFile.parse(serialized)
        XCTAssertEqual(reparsed.portrait?.overlay, true)

        // Absent and non-boolean values mean off.
        for json in [
            #"{ "version": 1, "portrait": { "x": 0, "y": 0, "w": 1, "h": 1 } }"#,
            #"{ "version": 1, "portrait": { "x": 0, "y": 0, "w": 1, "h": 1, "overlay": 1 } }"#,
        ] {
            XCTAssertEqual(ScreenRegionFile.parse(data(json)).portrait?.overlay, false, json)
        }
    }

    func testSerializeOmitsOverlayWhenOff() throws {
        let serialized = try XCTUnwrap(
            ScreenRegionFile.serialize(
                portrait: .region(ScreenRegion(x: 0, y: 0, w: 1, h: 1)), landscape: nil))
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("overlay"))
    }

    func testOverlayFlagPerOrientationThroughTheStore() throws {
        store.createProfile("P", touch: sampleTouch())
        let portrait = ScreenRegion(x: 0, y: 0.5, w: 1, h: 0.5, overlay: true)
        let landscape = ScreenRegion(x: 0, y: 0, w: 1, h: 1)
        XCTAssertTrue(store.writeScreen("P", portrait: .region(portrait), landscape: .region(landscape)))

        let read = try XCTUnwrap(store.readScreen("P"))
        XCTAssertEqual(read.portrait?.overlay, true)
        XCTAssertEqual(read.landscape?.overlay, false)
        XCTAssertEqual(read.portrait, .region(portrait))
        XCTAssertEqual(read.landscape, .region(landscape))
    }

    func testSerializeRoundTripIsByteStableWithOverlay() throws {
        let portrait = ScreenRegion(x: 0.1, y: 0.4, w: 0.9, h: 0.6, overlay: true)
        let first = try XCTUnwrap(
            ScreenRegionFile.serialize(portrait: .region(portrait), landscape: nil))
        let reparsed = ScreenRegionFile.parse(first)
        let second = try XCTUnwrap(
            ScreenRegionFile.serialize(portrait: reparsed.portrait, landscape: nil))
        XCTAssertEqual(first, second)
    }

    func testParseAcceptsFloatVersionOne() {
        // 1.0 is exactly representable: Int(exactly:) admits it.
        let result = ScreenRegionFile.parse(
            data(#"{ "version": 1.0, "portrait": { "x": 0, "y": 0, "w": 1, "h": 1 } }"#))
        XCTAssertNotNil(result.portrait)
    }

    // MARK: - Presets

    func testParsePresetStrings() {
        for (raw, preset) in [
            ("top", ScreenPreset.top),
            ("top-center", .topCenter),
            ("center", .center),
        ] {
            let result = ScreenRegionFile.parse(
                data("{ \"version\": 1, \"portrait\": \"\(raw)\" }"))
            XCTAssertEqual(result.portrait, .preset(preset), raw)
            XCTAssertTrue(result.findings.isEmpty, raw)
        }
    }

    func testParseUnknownPresetIsAFindingAndAbsent() {
        let result = ScreenRegionFile.parse(
            data(#"{ "version": 1, "portrait": "bottom" }"#))
        XCTAssertNil(result.portrait)
        XCTAssertTrue(result.findings.contains { $0.hasPrefix("S006") }, "\(result.findings)")
    }

    func testPresetSerializeRoundTripIsByteStable() throws {
        let first = try XCTUnwrap(
            ScreenRegionFile.serialize(
                portrait: .preset(.topCenter),
                landscape: .region(ScreenRegion(x: 0, y: 0, w: 1, h: 1))))
        let reparsed = ScreenRegionFile.parse(first)
        XCTAssertEqual(reparsed.portrait, .preset(.topCenter))
        let second = try XCTUnwrap(
            ScreenRegionFile.serialize(
                portrait: reparsed.portrait, landscape: reparsed.landscape))
        XCTAssertEqual(first, second)
    }

    func testPresetRegionComputesPerDevice() throws {
        // A 4:3 game on a phone-shaped portrait canvas: full safe
        // width, aspect-fit height, aligned per preset.
        func rect(_ preset: ScreenPreset, height: Double) -> ScreenRegion? {
            ScreenPresetPlacement.region(
                preset: preset,
                canvasWidth: 400, canvasHeight: height,
                safeTop: 60, safeBottom: 30, safeLeading: 0, safeTrailing: 0,
                isPortrait: true, aspect: 4.0 / 3.0)
        }
        let top = try XCTUnwrap(rect(.top, height: 800))
        XCTAssertEqual(top.y, 60.0 / 800.0, accuracy: 0.0001)
        XCTAssertEqual(top.w, 1.0, accuracy: 0.0001)
        XCTAssertEqual(top.h, 300.0 / 800.0, accuracy: 0.0001)

        let center = try XCTUnwrap(rect(.center, height: 800))
        // Available height 710, game 300: centered at 60 + 205.
        XCTAssertEqual(center.y, 265.0 / 800.0, accuracy: 0.0001)

        let topCenter = try XCTUnwrap(rect(.topCenter, height: 800))
        XCTAssertEqual(topCenter.y, (60.0 + 265.0) / 2.0 / 800.0, accuracy: 0.0001)

        // A taller canvas (a different device) yields a DIFFERENT
        // rect for the same preset: the preset is a rule, not a
        // stored rectangle.
        let tall = try XCTUnwrap(rect(.center, height: 900))
        XCTAssertNotEqual(center.y, tall.y)
    }

    func testPresetRegionLandscapeCentersForEveryPreset() {
        let rects = ScreenPreset.allCases.map { preset in
            ScreenPresetPlacement.region(
                preset: preset,
                canvasWidth: 800, canvasHeight: 400,
                safeTop: 0, safeBottom: 20, safeLeading: 60, safeTrailing: 60,
                isPortrait: false, aspect: 4.0 / 3.0)
        }
        XCTAssertEqual(Set(rects.map { $0?.y }).count, 1)
    }

    // MARK: - Serialize

    func testSerializeRoundTripIsByteStable() throws {
        let portrait = ScreenRegion(x: 0.1234567, y: 0.05, w: 0.8, h: 0.55)
        let first = try XCTUnwrap(
            ScreenRegionFile.serialize(portrait: .region(portrait), landscape: nil))
        let reparsed = ScreenRegionFile.parse(first)
        let second = try XCTUnwrap(
            ScreenRegionFile.serialize(portrait: reparsed.portrait, landscape: nil))
        XCTAssertEqual(first, second)
    }

    func testSerializeRoundsToFourDecimals() throws {
        let serialized = try XCTUnwrap(
            ScreenRegionFile.serialize(
                portrait: .region(ScreenRegion(x: 0.123456, y: 0, w: 0.876544, h: 1)),
                landscape: nil))
        let text = String(decoding: serialized, as: UTF8.self)
        XCTAssertTrue(text.contains("0.1235"), text)
        XCTAssertTrue(text.contains("0.8765"), text)
    }

    func testSerializeWritesOnlyExistingOrientations() throws {
        let serialized = try XCTUnwrap(
            ScreenRegionFile.serialize(
                portrait: nil, landscape: .region(ScreenRegion(x: 0, y: 0, w: 1, h: 1))))
        let text = String(decoding: serialized, as: UTF8.self)
        XCTAssertFalse(text.contains("portrait"))
        XCTAssertTrue(text.contains("landscape"))
    }

    func testSerializeBothNilReturnsNil() {
        XCTAssertNil(ScreenRegionFile.serialize(portrait: nil, landscape: nil))
    }

    // MARK: - Store

    func testReadScreenMissingFileReturnsNil() {
        store.createProfile("P", touch: sampleTouch())
        XCTAssertNil(store.readScreen("P"))
    }

    func testWriteAndReadScreen() throws {
        store.createProfile("P", touch: sampleTouch())
        let region = ScreenRegion(x: 0.1, y: 0.2, w: 0.5, h: 0.5)
        XCTAssertTrue(store.writeScreen("P", portrait: .region(region), landscape: nil))
        let read = try XCTUnwrap(store.readScreen("P"))
        XCTAssertEqual(read.portrait, .region(region))
        XCTAssertNil(read.landscape)
    }

    func testWriteScreenZeroOrientationsDeletesTheFile() {
        store.createProfile("P", touch: sampleTouch())
        store.writeScreen(
            "P", portrait: .region(ScreenRegion(x: 0, y: 0, w: 1, h: 1)), landscape: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.screenURL("P").path))
        XCTAssertTrue(store.writeScreen("P", portrait: nil, landscape: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.screenURL("P").path))
    }

    func testWriteScreenOnMissingProfileFails() {
        XCTAssertFalse(
            store.writeScreen(
                "Ghost", portrait: .region(ScreenRegion(x: 0, y: 0, w: 1, h: 1)), landscape: nil))
    }

    func testDuplicateCarriesScreenFile() throws {
        store.createProfile("P", touch: sampleTouch())
        let region = ScreenRegion(x: 0, y: 0.1, w: 0.9, h: 0.6)
        store.writeScreen("P", portrait: .region(region), landscape: nil)
        store.appendLog("P", file: ScreenRegionFile.fileName, line: "S005: test")

        let copy = try XCTUnwrap(store.duplicateProfile("P"))
        let read = try XCTUnwrap(store.readScreen(copy))
        XCTAssertEqual(read.portrait, .region(region))
        // Logs describe the original and must not travel.
        let copyLog = store.profileURL(copy)
            .appendingPathComponent("screen.json.log")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyLog.path))
    }

    func testRenameMovesScreenFile() throws {
        store.createProfile("P", touch: sampleTouch())
        let region = ScreenRegion(x: 0, y: 0, w: 0.5, h: 0.5)
        store.writeScreen("P", portrait: nil, landscape: .region(region))
        XCTAssertTrue(store.renameProfile(from: "P", to: "Q"))
        let read = try XCTUnwrap(store.readScreen("Q"))
        XCTAssertEqual(read.landscape, .region(region))
        XCTAssertNil(store.readScreen("P"))
    }

    func testDeleteRemovesScreenFile() {
        store.createProfile("P", touch: sampleTouch())
        store.writeScreen(
            "P", portrait: .region(ScreenRegion(x: 0, y: 0, w: 1, h: 1)), landscape: nil)
        XCTAssertTrue(store.deleteProfile("P"))
        XCTAssertNil(store.readScreen("P"))
    }

    func testPerFileLogPaths() throws {
        store.createProfile("P", touch: sampleTouch())
        store.appendLog("P", line: "V001: controls finding")
        store.appendLog("P", file: ScreenRegionFile.fileName, line: "S001: screen finding")
        let controlsLog = store.profileURL("P").appendingPathComponent("controls.json.log")
        let screenLog = store.profileURL("P").appendingPathComponent("screen.json.log")
        let controlsText = try String(contentsOf: controlsLog, encoding: .utf8)
        let screenText = try String(contentsOf: screenLog, encoding: .utf8)
        XCTAssertTrue(controlsText.contains("V001"))
        XCTAssertFalse(controlsText.contains("S001"))
        XCTAssertTrue(screenText.contains("S001"))
    }

    // MARK: - Resolution

    private func resolve(
        pin: LayoutPin, defaultName: String?
    ) -> ScreenResolution.Result {
        ScreenResolution.resolve(
            pin: pin, defaultProfileName: defaultName,
            readScreen: { self.store.readScreen($0) })
    }

    func testNamedPinReadsThatProfileOnly() {
        store.createProfile("Mine", touch: sampleTouch())
        store.createProfile("Default", touch: sampleTouch())
        let mine = ScreenRegion(x: 0, y: 0, w: 0.5, h: 0.5)
        store.writeScreen("Mine", portrait: .region(mine), landscape: nil)
        store.writeScreen(
            "Default", portrait: .region(ScreenRegion(x: 0.5, y: 0.5, w: 0.5, h: 0.5)),
            landscape: nil)

        let result = resolve(pin: .profile("Mine"), defaultName: "Default")
        XCTAssertEqual(result.portrait.placement?.region, mine)
        XCTAssertEqual(result.portrait.provenance, .profile("Mine"))
    }

    func testNamedPinIsTerminalOverTheDefault() {
        // The pinned profile has no screen file. A default region
        // exists. The pin is terminal: engine-auto, never the
        // default's region.
        store.createProfile("Mine", touch: sampleTouch())
        store.createProfile("Default", touch: sampleTouch())
        store.writeScreen(
            "Default", portrait: .region(ScreenRegion(x: 0, y: 0, w: 1, h: 1)), landscape: nil)

        let result = resolve(pin: .profile("Mine"), defaultName: "Default")
        XCTAssertNil(result.portrait.placement?.region)
        XCTAssertEqual(result.portrait.provenance, .engineAuto)
        XCTAssertNil(result.landscape.placement?.region)
    }

    func testGamePinSkipsTheDefault() {
        store.createProfile("Default", touch: sampleTouch())
        store.writeScreen(
            "Default", portrait: .region(ScreenRegion(x: 0, y: 0, w: 1, h: 1)), landscape: nil)

        let result = resolve(pin: .gameLayout, defaultName: "Default")
        XCTAssertEqual(result.portrait.provenance, .engineAuto)
        XCTAssertNil(result.portrait.placement?.region)
    }

    func testDefaultPinAndChainReadTheDefault() {
        store.createProfile("Default", touch: sampleTouch())
        let region = ScreenRegion(x: 0, y: 0.25, w: 1, h: 0.5)
        store.writeScreen("Default", portrait: .region(region), landscape: nil)

        for pin in [LayoutPin.defaultProfile, .followChain] {
            let result = resolve(pin: pin, defaultName: "Default")
            XCTAssertEqual(result.portrait.placement?.region, region, "\(pin)")
            XCTAssertEqual(result.portrait.provenance, .profile("Default"), "\(pin)")
        }
    }

    func testNoDefaultMeansEngineAuto() {
        let result = resolve(pin: .followChain, defaultName: nil)
        XCTAssertEqual(result.portrait.provenance, .engineAuto)
        XCTAssertEqual(result.landscape.provenance, .engineAuto)
    }

    func testOrientationsResolveIndependently() {
        store.createProfile("P", touch: sampleTouch())
        let landscape = ScreenRegion(x: 0.1, y: 0, w: 0.8, h: 1)
        store.writeScreen("P", portrait: nil, landscape: .region(landscape))

        let result = resolve(pin: .profile("P"), defaultName: nil)
        XCTAssertNil(result.portrait.placement?.region)
        XCTAssertEqual(result.portrait.provenance, .engineAuto)
        XCTAssertEqual(result.landscape.placement?.region, landscape)
        XCTAssertEqual(result.landscape.provenance, .profile("P"))
    }

    func testInvalidScreenFileResolvesAsAbsent() throws {
        store.createProfile("P", touch: sampleTouch())
        try Data("garbage".utf8).write(to: store.screenURL("P"))

        let result = resolve(pin: .profile("P"), defaultName: nil)
        XCTAssertNil(result.portrait.placement?.region)
        XCTAssertEqual(result.portrait.provenance, .engineAuto)
    }

    // MARK: - Migration interplay

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

    private func migrationContext(
        userTouch: TouchSection, record: MigrationRecord = MigrationRecord()
    ) -> ProfileMigration.Context {
        let builtins = builtins()
        return ProfileMigration.Context(
            gameID: "game-1",
            gameTitle: "Game",
            userTouch: userTouch,
            manifestTouch: nil,
            pinFileExists: false,
            record: record,
            existingProfiles: store.listProfiles(),
            profileCanonicalBytes: { name in
                guard let touch = self.store.readProfile(name)?.touch else { return nil }
                return ProfileMaterializer.canonicalBytes(
                    ProfileMaterializer.materialize(
                        user: touch, manifest: nil, builtins: builtins,
                        metrics: .reference))
            },
            profileHasScreen: { name in
                FileManager.default.fileExists(atPath: self.store.screenURL(name).path)
            }
        )
    }

    func testMigrationDedupeSkipsScreenBearingProfiles() {
        // A profile whose controls bytes match the migrating game's
        // layout, but which carries a screen region: pinning to it
        // would silently move the game's screen.
        let touch = sampleTouch()
        let materialized = ProfileMaterializer.materialize(
            user: touch, manifest: nil, builtins: builtins(), metrics: .reference)
        store.createProfile("Twin", touch: materialized.section)
        store.writeScreen(
            "Twin", portrait: .region(ScreenRegion(x: 0, y: 0, w: 0.5, h: 0.5)), landscape: nil)

        let action = ProfileMigration.decide(
            context: migrationContext(userTouch: touch), builtins: builtins())
        guard case .createAndPin = action else {
            return XCTFail("expected createAndPin, got \(action)")
        }
    }

    func testMigrationDedupeStillMatchesScreenlessProfiles() {
        let touch = sampleTouch()
        let materialized = ProfileMaterializer.materialize(
            user: touch, manifest: nil, builtins: builtins(), metrics: .reference)
        store.createProfile("Twin", touch: materialized.section)

        let action = ProfileMigration.decide(
            context: migrationContext(userTouch: touch), builtins: builtins())
        guard case .pinToExisting(let profile, _, _) = action else {
            return XCTFail("expected pinToExisting, got \(action)")
        }
        XCTAssertEqual(profile, "Twin")
    }

    func testMigrationRecordIdempotenceWithScreenFilePresent() {
        // The record hash covers the game's own touch section, not
        // the profile folder: adding screen.json to the profile
        // later must not re-trigger migration.
        let touch = sampleTouch()
        let materialized = ProfileMaterializer.materialize(
            user: touch, manifest: nil, builtins: builtins(), metrics: .reference)
        let canonical = ProfileMaterializer.canonicalBytes(materialized)
        let hash = FNV1a.hash64(canonical)
        var record = MigrationRecord()
        record.games["game-1"] = MigrationRecord.Entry(hash: hash, profile: "Mine")

        store.createProfile("Mine", touch: materialized.section)
        store.writeScreen(
            "Mine", portrait: .region(ScreenRegion(x: 0, y: 0, w: 1, h: 1)), landscape: nil)

        let action = ProfileMigration.decide(
            context: migrationContext(userTouch: touch, record: record),
            builtins: builtins())
        XCTAssertEqual(action, .none)
    }
}

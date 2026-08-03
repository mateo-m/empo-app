import Foundation
import XCTest

@testable import GameProbe

final class ManagedMkxpConfigTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedMkxpConfigTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testOverlayStringPassesSparseKeysThrough() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "fontScale": 1.5 }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let json = try XCTUnwrap(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir
            )
        )
        let payload = try parseOverlayJSON(json)
        XCTAssertEqual(payload["fontScale"] as? Double, 1.5)
        XCTAssertNil(payload["defScreenW"])
        XCTAssertNil(payload["defScreenH"])
    }

    func testOverlayStringNeutralizesScreenKeysTheBaseDefines() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "defScreenW": 640, "defScreenH": 480, "smoothScaling": 1 }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        // No user overlay at all: the neutralizing patches alone must
        // still produce an overlay (regression: a plain desktop-shipped
        // config would otherwise reach the engine with defScreen sizing).
        let json = try XCTUnwrap(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir
            )
        )
        let payload = try parseOverlayJSON(json)
        XCTAssertTrue(payload["defScreenW"] is NSNull)
        XCTAssertTrue(payload["defScreenH"] is NSNull)
        XCTAssertNil(payload["smoothScaling"])
    }

    func testOverlayStringHandAddedScreenKeyBeatsNullPatch() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "defScreenW": 640 }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try """
            { "defScreenW": 800 }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let json = try XCTUnwrap(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir
            )
        )
        let payload = try parseOverlayJSON(json)
        XCTAssertEqual(payload["defScreenW"] as? Int, 800)
    }

    func testOverlayStringUnparseableBaseNeutralizesConservatively() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try "{ not json".write(
            to: gameDir.appendingPathComponent("mkxp.json"),
            atomically: true,
            encoding: .utf8
        )

        let json = try XCTUnwrap(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir
            )
        )
        let payload = try parseOverlayJSON(json)
        XCTAssertTrue(payload["defScreenW"] is NSNull)
        XCTAssertTrue(payload["defScreenH"] is NSNull)
    }

    func testOverlayStringAppliesVsyncPatchOnlyWhenConditionsMet() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "vsync": true, "defScreenW": 640 }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let json = try XCTUnwrap(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir
            )
        )
        let payload = try parseOverlayJSON(json)
        XCTAssertEqual(payload["syncToRefreshrate"] as? Bool, true)
        XCTAssertNil(payload["vsync"])
        XCTAssertTrue(payload["defScreenW"] is NSNull)
        XCTAssertNil(payload["defScreenH"])
    }

    func testOverlayStringUserSyncToRefreshrateBeatsVsyncPatch() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "vsync": true }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try """
            { "syncToRefreshrate": false }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let json = try XCTUnwrap(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir
            )
        )
        let payload = try parseOverlayJSON(json)
        XCTAssertEqual(payload["syncToRefreshrate"] as? Bool, false)
    }

    func testOverlayStringUnparseableOverlayYieldsPatchesOnly() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "vsync": true, "defScreenW": 640 }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try "{ not json".write(
            to: stateDir.appendingPathComponent("mkxp.json"),
            atomically: true,
            encoding: .utf8
        )

        var logged: String?
        let json = try XCTUnwrap(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir,
                onUnparseableOverlay: { logged = $0 }
            )
        )
        XCTAssertNotNil(logged)
        let payload = try parseOverlayJSON(json)
        XCTAssertEqual(payload["syncToRefreshrate"] as? Bool, true)
        XCTAssertTrue(payload["defScreenW"] is NSNull)
    }

    func testOverlayStringNilWhenNothingToSend() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        XCTAssertNil(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir
            )
        )
    }

    func testOverlayStringNilForPlainBaseWithoutSpecialKeys() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "smoothScaling": 1, "patches": ["base.zip"] }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertNil(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir
            )
        )
    }

    func testUIWritePreservesHandAddedOverlayKeys() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "smoothScaling": 1 }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try """
            { "frameRate": 120, "smoothScaling": 0 }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(
            ManagedMkxpConfig.updateManaged(
                overrides: MkxpEngineValues(fontScale: 1.2),
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )

        let overlayData = try Data(
            contentsOf: stateDir.appendingPathComponent("mkxp.json"))
        let overlay = try XCTUnwrap(
            JSONSerialization.jsonObject(with: overlayData) as? [String: Any])
        XCTAssertEqual(overlay["frameRate"] as? Int, 120)
        XCTAssertEqual(overlay["smoothScaling"] as? Int, 0)
        XCTAssertEqual(overlay["fontScale"] as? Double, 1.2)

        let json = try XCTUnwrap(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir
            )
        )
        let payload = try parseOverlayJSON(json)
        XCTAssertEqual(payload["frameRate"] as? Int, 120)
        XCTAssertEqual(payload["fontScale"] as? Double, 1.2)
    }

    func testUnparseableBaseAllowsOverlayWrites() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try "{ not json".write(
            to: gameDir.appendingPathComponent("mkxp.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(ManagedMkxpConfig.isDevConfigUnparseable(gameDirectory: gameDir))
        XCTAssertTrue(
            ManagedMkxpConfig.updateManaged(
                overrides: MkxpEngineValues(smoothScaling: true),
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )

        let overlay = try readOverlayConfig(stateDir)
        XCTAssertEqual(overlay["smoothScaling"] as? Int, 1)
    }

    func testWriteOverlayStoresOnlyEngineKeys() throws {
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        XCTAssertTrue(
            ManagedMkxpConfig.writeOverlay(
                overrides: MkxpEngineValues(fontScale: 1.5),
                stateDirectory: stateDir
            )
        )

        let overlay = try readOverlayConfig(stateDir)
        XCTAssertEqual(overlay["fontScale"] as? Double, 1.5)
        XCTAssertNil(overlay["patches"])
    }

    func testResetFieldRemovesOverlayKey() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "fontScale": 1.2 }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try """
            { "fontScale": 2.0, "frameRate": 120 }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(
            ManagedMkxpConfig.resetField(
                .fontScale,
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )

        // The hand-added non-engine key survives; only the reset
        // key is gone.
        let overlay = try readOverlayConfig(stateDir)
        XCTAssertNil(overlay["fontScale"])
        XCTAssertEqual(overlay["frameRate"] as? Int, 120)
    }

    func testResetLastFieldDeletesTheEmptyOverlay() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "fontScale": 2.0 }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(
            ManagedMkxpConfig.resetField(
                .fontScale,
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ManagedMkxpConfig.overlayConfigURL(in: stateDir).path
        ))
    }

    func testResetFieldVsyncRemovesHandWrittenVsyncKey() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "vsync": true, "frameRate": 120 }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(
            ManagedMkxpConfig.resetField(
                .vsync,
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )

        let overlay = try readOverlayConfig(stateDir)
        XCTAssertNil(overlay["vsync"])
        XCTAssertNil(overlay["syncToRefreshrate"])
        XCTAssertEqual(overlay["frameRate"] as? Int, 120)
    }

    func testResetAllKeepsHandAddedNonEngineKeys() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            {
              "fontScale": 2.0,
              "pathCache": false,
              "enableHires": true,
              "framebufferScalingFactor": 2.0,
              "frameRate": 120
            }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(
            ManagedMkxpConfig.resetAllEngineFields(
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )

        let overlay = try readOverlayConfig(stateDir)
        XCTAssertEqual(overlay as NSDictionary, ["frameRate": 120] as NSDictionary)
    }

    func testResetAllDeletesEmptyOverlay() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "fontScale": 2.0, "pathCache": false }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(
            ManagedMkxpConfig.resetAllEngineFields(
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ManagedMkxpConfig.overlayConfigURL(in: stateDir).path
        ))
    }

    func testLegacyMigrationBuildsSparseOverlayAndStripsKeys() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            {
              "pathCache": true,
              "patches": ["keep-me.zip"]
            }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        try """
            {
              "smoothScaling": 1,
              "fontScale": 9.9,
              "patches": ["stale.zip"]
            }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let settingsJSON = """
            {
              "smoothScaling": true,
              "renderScale": "x2",
              "speedMultiplier": 4,
              "vsync": false
            }
            """
        try settingsJSON.write(
            to: stateDir.appendingPathComponent("game_settings.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(
            ManagedMkxpConfig.migrateLegacyEngineSettingsIfNeeded(
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )

        let overlay = try readOverlayConfig(stateDir)
        XCTAssertEqual(overlay["smoothScaling"] as? Int, 1)
        XCTAssertEqual(overlay["enableHires"] as? Bool, true)
        XCTAssertEqual(overlay["framebufferScalingFactor"] as? Double, 2.0)
        XCTAssertEqual(overlay["syncToRefreshrate"] as? Bool, false)
        XCTAssertNil(overlay["pathCache"])
        XCTAssertNil(overlay["patches"])
        // The migration REBUILDS the overlay; the pre-existing
        // overlay's stale engine key must be gone, not merged in.
        XCTAssertNil(overlay["fontScale"])

        let settingsData = try Data(contentsOf: stateDir.appendingPathComponent("game_settings.json"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        XCTAssertEqual(settings["speedMultiplier"] as? Int, 4)
        XCTAssertNil(settings["smoothScaling"])
        XCTAssertNil(settings["renderScale"])
        XCTAssertNil(settings["vsync"])

        XCTAssertTrue(
            ManagedMkxpConfig.migrateLegacyEngineSettingsIfNeeded(
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )
        // The repeat call is a no-op: the overlay dict stays
        // identical, not just "returned true".
        let overlayAfterRepeat = try readOverlayConfig(stateDir)
        XCTAssertEqual(overlay as NSDictionary, overlayAfterRepeat as NSDictionary)
    }

    func testLegacyMigrationRenderScaleX1DisablesHiresWithoutFactor() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try """
            { "renderScale": "x1" }
            """.write(
            to: stateDir.appendingPathComponent("game_settings.json"),
            atomically: true, encoding: .utf8)

        XCTAssertTrue(
            ManagedMkxpConfig.migrateLegacyEngineSettingsIfNeeded(
                stateDirectory: stateDir, gameDirectory: gameDir))

        let overlay = try readOverlayConfig(stateDir)
        XCTAssertEqual(overlay["enableHires"] as? Bool, false)
        XCTAssertNil(overlay["framebufferScalingFactor"])
    }

    func testLegacyMigrationRenderScaleX4EnablesHiresWithFactor() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try """
            { "renderScale": "x4" }
            """.write(
            to: stateDir.appendingPathComponent("game_settings.json"),
            atomically: true, encoding: .utf8)

        XCTAssertTrue(
            ManagedMkxpConfig.migrateLegacyEngineSettingsIfNeeded(
                stateDirectory: stateDir, gameDirectory: gameDir))

        let overlay = try readOverlayConfig(stateDir)
        XCTAssertEqual(overlay["enableHires"] as? Bool, true)
        XCTAssertEqual(overlay["framebufferScalingFactor"] as? Double, 4.0)
    }

    func testLegacyMigrationUnknownRenderScaleEmitsNeitherKey() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // pathCache keeps the rebuilt overlay non-empty, so the
        // file survives and the absent keys are observable.
        try """
            { "renderScale": "x8", "pathCache": true }
            """.write(
            to: stateDir.appendingPathComponent("game_settings.json"),
            atomically: true, encoding: .utf8)

        XCTAssertTrue(
            ManagedMkxpConfig.migrateLegacyEngineSettingsIfNeeded(
                stateDirectory: stateDir, gameDirectory: gameDir))

        let overlay = try readOverlayConfig(stateDir)
        XCTAssertEqual(overlay["pathCache"] as? Bool, true)
        XCTAssertNil(overlay["enableHires"])
        XCTAssertNil(overlay["framebufferScalingFactor"])
    }

    func testReadEffectiveMergesBaseAndOverlay() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "fontScale": 1.2, "pathCache": true }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try """
            { "fontScale": 2.0 }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let effective = ManagedMkxpConfig.readEffective(
            stateDirectory: stateDir,
            gameDirectory: gameDir
        )
        XCTAssertEqual(effective.fontScale, 2.0)
        XCTAssertEqual(effective.pathCache, true)
        XCTAssertEqual(
            ManagedMkxpConfig.provenance(for: .fontScale, stateDirectory: stateDir),
            .yours
        )
        XCTAssertEqual(
            ManagedMkxpConfig.provenance(for: .pathCache, stateDirectory: stateDir),
            .game
        )
    }

    func testReadDataPathAbsentByDefault() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

        let dataPath = ManagedMkxpConfig.readDataPath(
            stateDirectory: stateDir, gameDirectory: gameDir)
        XCTAssertNil(dataPath.org)
        XCTAssertNil(dataPath.app)
        XCTAssertFalse(dataPath.isDeclared)
    }

    func testReadDataPathFromBaseConfig() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

        try """
            {
                // JSON5-style comment must not break the read
                "dataPathOrg": ".",
                "dataPathApp": "reborn",
            }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let dataPath = ManagedMkxpConfig.readDataPath(
            stateDirectory: stateDir, gameDirectory: gameDir)
        XCTAssertEqual(dataPath.org, ".")
        XCTAssertEqual(dataPath.app, "reborn")
        XCTAssertTrue(dataPath.isDeclared)
    }

    func testReadDataPathOverlayWinsOverBase() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "dataPathOrg": "dev", "dataPathApp": "game" }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try """
            { "dataPathApp": "game-v2" }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let dataPath = ManagedMkxpConfig.readDataPath(
            stateDirectory: stateDir, gameDirectory: gameDir)
        XCTAssertEqual(dataPath.org, "dev")
        XCTAssertEqual(dataPath.app, "game-v2")
    }

    func testReadDataPathBlankAndNonStringValuesReadAsAbsent() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

        try """
            { "dataPathOrg": "   ", "dataPathApp": 42 }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let dataPath = ManagedMkxpConfig.readDataPath(
            stateDirectory: stateDir, gameDirectory: gameDir)
        XCTAssertNil(dataPath.org)
        XCTAssertNil(dataPath.app)
        XCTAssertFalse(dataPath.isDeclared)
    }

    func testReadDataPathBlankOverlayValueRemovesBaseValue() throws {
        // A blank overlay string does not fall through to the base
        // value; it reads as absent for the merged pair.
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "dataPathOrg": "dev", "dataPathApp": "game" }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try """
            { "dataPathApp": "   " }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let dataPath = ManagedMkxpConfig.readDataPath(
            stateDirectory: stateDir, gameDirectory: gameDir)
        XCTAssertEqual(dataPath.org, "dev")
        XCTAssertNil(dataPath.app)
    }

    func testReadDataPathNullOverlayValueRemovesBaseValue() throws {
        // A JSON null in the overlay overwrites the base value in
        // the merged dict; the null is not a string, so the key
        // reads as absent.
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "dataPathOrg": "dev", "dataPathApp": "game" }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)
        try """
            { "dataPathApp": null }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let dataPath = ManagedMkxpConfig.readDataPath(
            stateDirectory: stateDir, gameDirectory: gameDir)
        XCTAssertEqual(dataPath.org, "dev")
        XCTAssertNil(dataPath.app)
    }

    func testOverlayDefinesRenderScaleWithOnlyScalingFactor() throws {
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "framebufferScalingFactor": 2.0 }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(ManagedMkxpConfig.overlayDefines(.renderScale, in: stateDir))
        XCTAssertFalse(ManagedMkxpConfig.overlayDefines(.fontScale, in: stateDir))
    }

    func testRemoveLegacyEngineConfigDirectory() throws {
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        let engineDir = stateDir.appendingPathComponent(".engine", isDirectory: true)
        try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)
        try "{\"smoothScaling\":0}".write(
            to: engineDir.appendingPathComponent("mkxp.json"),
            atomically: true,
            encoding: .utf8
        )

        ManagedMkxpConfig.removeLegacyEngineConfigDirectory(in: stateDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: engineDir.path))
    }

    private func readOverlayConfig(_ stateDir: URL) throws -> [String: Any] {
        let url = ManagedMkxpConfig.overlayConfigURL(in: stateDir)
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func parseOverlayJSON(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}

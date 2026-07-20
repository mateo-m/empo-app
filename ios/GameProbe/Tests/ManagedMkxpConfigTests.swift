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
        XCTAssertTrue(payload["defScreenW"] is NSNull)
        XCTAssertTrue(payload["defScreenH"] is NSNull)
    }

    func testOverlayStringAlwaysIncludesNullScreenPatchesWhenNonNil() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "pathCache": false }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let json = try XCTUnwrap(
            ManagedMkxpConfig.overlayJSONString(
                gameDirectory: gameDir,
                stateDirectory: stateDir
            )
        )
        let payload = try parseOverlayJSON(json)
        XCTAssertEqual(payload["pathCache"] as? Bool, false)
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
        XCTAssertTrue(payload["defScreenH"] is NSNull)
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

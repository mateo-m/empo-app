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

    func testComposeOverlayBeatsBaseAndPreservesDevKeys() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            {
              "smoothScaling": 1,
              "fontScale": 1.0,
              "patches": ["overlay.zip"],
              "scriptPatches": ["foo.rb"]
            }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        try """
            { "smoothScaling": 0, "fontScale": 1.5 }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ManagedMkxpConfig.compose(gameDirectory: gameDir, stateDirectory: stateDir),
            .composed
        )

        let composed = try readComposedConfig(stateDir)
        XCTAssertEqual(composed["smoothScaling"] as? Int, 0)
        XCTAssertEqual(composed["fontScale"] as? Double, 1.5)
        XCTAssertEqual(composed["patches"] as? [String], ["overlay.zip"])
        XCTAssertEqual(composed["scriptPatches"] as? [String], ["foo.rb"])
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

        let composed = try readComposedConfig(stateDir)
        XCTAssertEqual(composed["frameRate"] as? Int, 120)
    }

    func testComposeAppliesNormalizationsOnlyToComposedOutput() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            {
              "vsync": true,
              "syntaxTransform": "legacy",
              "defScreenW": 640
            }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ManagedMkxpConfig.compose(gameDirectory: gameDir, stateDirectory: stateDir),
            .composed
        )

        let composed = try readComposedConfig(stateDir)
        XCTAssertEqual(composed["syncToRefreshrate"] as? Bool, true)
        XCTAssertNil(composed["vsync"])
        XCTAssertNil(composed["syntaxTransform"])
        XCTAssertNil(composed["defScreenW"])

        let baseRaw = try String(
            contentsOf: gameDir.appendingPathComponent("mkxp.json"),
            encoding: .utf8
        )
        XCTAssertTrue(baseRaw.contains("\"vsync\""))
        XCTAssertTrue(baseRaw.contains("\"syntaxTransform\""))
    }

    func testUnparseableBaseRemovesComposedFileAndBlocksOverlayWrites() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try "{ not json".write(
            to: gameDir.appendingPathComponent("mkxp.json"),
            atomically: true,
            encoding: .utf8
        )

        let staleComposed = ManagedMkxpConfig.composedConfigURL(in: stateDir)
        try FileManager.default.createDirectory(
            at: ManagedMkxpConfig.engineConfigDirectory(in: stateDir),
            withIntermediateDirectories: true
        )
        try "{\"smoothScaling\": 0}".write(to: staleComposed, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ManagedMkxpConfig.compose(gameDirectory: gameDir, stateDirectory: stateDir),
            .readOnly
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleComposed.path))
        XCTAssertTrue(ManagedMkxpConfig.isDevConfigUnparseable(gameDirectory: gameDir))

        XCTAssertFalse(
            ManagedMkxpConfig.updateManaged(
                overrides: MkxpEngineValues(smoothScaling: true),
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )
    }

    func testComposeOverlayOnlyAndBaseOnly() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "pathCache": true }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ManagedMkxpConfig.compose(gameDirectory: gameDir, stateDirectory: stateDir),
            .composed
        )
        var composed = try readComposedConfig(stateDir)
        XCTAssertEqual(composed["pathCache"] as? Bool, true)

        try? FileManager.default.removeItem(at: stateDir.appendingPathComponent("mkxp.json"))
        try """
            { "fontScale": 1.2 }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ManagedMkxpConfig.compose(gameDirectory: gameDir, stateDirectory: stateDir),
            .composed
        )
        composed = try readComposedConfig(stateDir)
        XCTAssertEqual(composed["fontScale"] as? Double, 1.2)

        try? FileManager.default.removeItem(at: gameDir.appendingPathComponent("mkxp.json"))
        XCTAssertEqual(
            ManagedMkxpConfig.compose(gameDirectory: gameDir, stateDirectory: stateDir),
            .noSource
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ManagedMkxpConfig.composedConfigURL(in: stateDir).path
            )
        )
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

        let composed = try readComposedConfig(stateDir)
        XCTAssertEqual(composed["fontScale"] as? Double, 1.2)
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

        let composed = try readComposedConfig(stateDir)
        XCTAssertEqual(composed["pathCache"] as? Bool, true)
        XCTAssertEqual(composed["patches"] as? [String], ["keep-me.zip"])

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

    private func readOverlayConfig(_ stateDir: URL) throws -> [String: Any] {
        let url = ManagedMkxpConfig.overlayConfigURL(in: stateDir)
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func readComposedConfig(_ stateDir: URL) throws -> [String: Any] {
        let url = ManagedMkxpConfig.composedConfigURL(in: stateDir)
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
}

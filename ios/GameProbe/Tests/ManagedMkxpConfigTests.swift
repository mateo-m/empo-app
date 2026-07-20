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

    func testSeedCopiesDevBaseAndStripsNormalizations() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let devJSON = """
            {
              "smoothScaling": 1,
              "vsync": true,
              "syntaxTransform": "legacy",
              "defScreenW": 640,
              "patches": ["overlay.zip"]
            }
            """
        try devJSON.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(ManagedMkxpConfig.seed(from: gameDir, to: stateDir))

        let managedURL = ManagedMkxpConfig.managedConfigURL(in: stateDir)
        let raw = try String(contentsOf: managedURL, encoding: .utf8)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])

        XCTAssertEqual(config["smoothScaling"] as? Int, 1)
        XCTAssertEqual(config["syncToRefreshrate"] as? Bool, true)
        XCTAssertNil(config["vsync"])
        XCTAssertNil(config["syntaxTransform"])
        XCTAssertNil(config["defScreenW"])
        XCTAssertEqual(config["patches"] as? [String], ["overlay.zip"])
    }

    func testUnparseableDevFileRemovesManagedCopyAndBlocksWrites() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try "{ not json".write(
            to: gameDir.appendingPathComponent("mkxp.json"),
            atomically: true,
            encoding: .utf8
        )

        let staleManaged = stateDir.appendingPathComponent("mkxp.json")
        try "{\"smoothScaling\": 0}".write(to: staleManaged, atomically: true, encoding: .utf8)

        XCTAssertFalse(ManagedMkxpConfig.seed(from: gameDir, to: stateDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleManaged.path))
        XCTAssertTrue(ManagedMkxpConfig.isDevConfigUnparseable(gameDirectory: gameDir))

        XCTAssertFalse(
            ManagedMkxpConfig.updateManaged(
                overrides: MkxpEngineValues(smoothScaling: true),
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )
    }

    func testUpdateManagedPreservesUnknownKeys() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "customFlag": true, "fontScale": 1.0 }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(
            ManagedMkxpConfig.updateManaged(
                overrides: MkxpEngineValues(fontScale: 1.5),
                stateDirectory: stateDir,
                gameDirectory: gameDir
            )
        )

        let config = try readManagedConfig(stateDir)
        XCTAssertEqual(config["fontScale"] as? Double, 1.5)
        XCTAssertEqual(config["customFlag"] as? Bool, true)
    }

    func testResetFieldCopiesDevValueWhenDefined() throws {
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

        let devDefaults = ManagedMkxpConfig.readGameDefaults(from: gameDir)
        XCTAssertTrue(
            ManagedMkxpConfig.resetField(
                .fontScale,
                stateDirectory: stateDir,
                gameDirectory: gameDir,
                devDefaults: devDefaults
            )
        )

        let config = try readManagedConfig(stateDir)
        XCTAssertEqual(config["fontScale"] as? Double, 1.2)
    }

    func testResetFieldRemovesKeyWhenDevUndefined() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "fontScale": 2.0 }
            """.write(to: stateDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

        let devDefaults = ManagedMkxpConfig.readGameDefaults(from: gameDir)
        XCTAssertTrue(
            ManagedMkxpConfig.resetField(
                .fontScale,
                stateDirectory: stateDir,
                gameDirectory: gameDir,
                devDefaults: devDefaults
            )
        )

        let config = try readManagedConfig(stateDir)
        XCTAssertNil(config["fontScale"])
    }

    func testLegacyMigrationProjectsThenStripsKeys() throws {
        let gameDir = tempRoot.appendingPathComponent("Game", isDirectory: true)
        let stateDir = tempRoot.appendingPathComponent("EmpoState", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        try """
            { "pathCache": true }
            """.write(to: gameDir.appendingPathComponent("mkxp.json"), atomically: true, encoding: .utf8)

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

        let managed = try readManagedConfig(stateDir)
        XCTAssertEqual(managed["smoothScaling"] as? Int, 1)
        XCTAssertEqual(managed["enableHires"] as? Bool, true)
        XCTAssertEqual(managed["framebufferScalingFactor"] as? Double, 2.0)
        XCTAssertEqual(managed["syncToRefreshrate"] as? Bool, false)
        XCTAssertEqual(managed["pathCache"] as? Bool, true)

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

    private func readManagedConfig(_ stateDir: URL) throws -> [String: Any] {
        let url = ManagedMkxpConfig.managedConfigURL(in: stateDir)
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
}

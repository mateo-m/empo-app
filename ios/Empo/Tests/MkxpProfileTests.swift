import XCTest

@testable import Empo

final class MkxpProfileTests: XCTestCase {

    func testScanRunsAgainOnlyWhenAScriptChanges() throws {
        let container = GameContainer(folderName: "mkxp-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container.url) }
        let script = container.gameURL.appendingPathComponent("Data/Scripts/Main.rb")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x = 1\n".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertFalse(MkxpProfile.load(for: container).modernRubyScripts)

        let stored = container.metadataURL.appendingPathComponent("mkxp-profile.json")
        var profile = try JSONDecoder().decode(MkxpProfile.self, from: Data(contentsOf: stored))
        profile.modernRubyScripts = true
        try JSONEncoder().encode(profile).write(to: stored)
        XCTAssertTrue(MkxpProfile.load(for: container).modernRubyScripts)

        try "x = 1\ny = 2\n".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertFalse(MkxpProfile.load(for: container).modernRubyScripts)
    }

    func testTheRGSSVersionComesFromAnyINIFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkxp-rgss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[Game]\nScripts=Scripts.rvdata2\n"
            .write(to: root.appendingPathComponent("Custom.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MkxpRuntimeProbe.rgssVersion(in: root), 3)
    }
}

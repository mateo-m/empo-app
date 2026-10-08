import Foundation
import XCTest

@testable import GameProbe

final class SkinFilesTests: XCTestCase {

    private var root: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SkinFilesTests-\(UUID().uuidString)")
        folder = root.appendingPathComponent("Pink")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ name: String, _ contents: String = "art") throws {
        try Data(contents.utf8).write(to: folder.appendingPathComponent(name))
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - Art lookup

    func testNoArtReturnsNil() {
        let result = SkinFiles.artLookup(profileFolder: folder, orientation: .portrait)
        XCTAssertNil(result.url)
        XCTAssertEqual(result.findings, [])
    }

    func testFindsEachExtension() throws {
        for ext in ["png", "jpg", "jpeg"] {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try touch("skin-portrait.\(ext)")

            let portrait = SkinFiles.artLookup(profileFolder: folder, orientation: .portrait)
            XCTAssertEqual(portrait.url?.lastPathComponent, "skin-portrait.\(ext)")
            XCTAssertNil(SkinFiles.artLookup(profileFolder: folder, orientation: .landscape).url)
        }
    }

    func testCaseInsensitive() throws {
        try touch("Skin-Portrait.JPG")
        let result = SkinFiles.artLookup(profileFolder: folder, orientation: .portrait)
        XCTAssertEqual(result.url?.lastPathComponent, "Skin-Portrait.JPG")
    }

    func testPrecedenceAndWarning() throws {
        try touch("skin-portrait.jpg")
        try touch("skin-portrait.png")
        let result = SkinFiles.artLookup(profileFolder: folder, orientation: .portrait)
        XCTAssertEqual(result.url?.lastPathComponent, "skin-portrait.png")
        XCTAssertTrue(result.findings.contains { $0.hasPrefix("W-K1") })
    }

    // MARK: - Settings

    func testSettingsMissingIsDefault() {
        let result = SkinFiles.readSettings(profileFolder: folder)
        XCTAssertFalse(result.settings.showButtonOutlines)
        XCTAssertEqual(result.findings, [])
    }

    func testSettingsRoundTrip() throws {
        try SkinFiles.writeSettings(SkinSettings(showButtonOutlines: true), profileFolder: folder)
        let result = SkinFiles.readSettings(profileFolder: folder)
        XCTAssertTrue(result.settings.showButtonOutlines)
        XCTAssertEqual(result.findings, [])
    }

    func testSettingsMalformed() throws {
        try touch(SkinFiles.settingsFileName, "[]")
        var result = SkinFiles.readSettings(profileFolder: folder)
        XCTAssertEqual(result.settings, .defaults)
        XCTAssertTrue(result.findings.contains { $0.hasPrefix("K001") })

        try touch(SkinFiles.settingsFileName, #"{"showButtonOutlines":"yes"}"#)
        result = SkinFiles.readSettings(profileFolder: folder)
        XCTAssertEqual(result.settings, .defaults)
        XCTAssertTrue(result.findings.contains { $0.hasPrefix("K002") })

        try touch(SkinFiles.settingsFileName, #"{"showButtonOutlines":true,"future":1}"#)
        result = SkinFiles.readSettings(profileFolder: folder)
        XCTAssertTrue(result.settings.showButtonOutlines)
        XCTAssertEqual(result.findings, [])
    }

    // MARK: - Install / remove

    func testInstallReplacesOtherExtensions() throws {
        try touch("skin-portrait.png", "old")
        let data = Data("new jpeg bytes".utf8)

        let url = try SkinFiles.installArt(
            data, fileExtension: "JPG", orientation: .portrait, profileFolder: folder)

        XCTAssertEqual(url.lastPathComponent, "skin-portrait.jpg")
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try names(), ["skin-portrait.jpg"])
    }

    func testInstallRejectsUnknownExtension() throws {
        try touch("skin-portrait.png", "old")
        XCTAssertThrowsError(
            try SkinFiles.installArt(
                Data("gif".utf8), fileExtension: "gif", orientation: .portrait,
                profileFolder: folder))
        XCTAssertEqual(try names(), ["skin-portrait.png"])
    }

    func testRemoveArt() throws {
        try touch("skin-portrait.png")
        try touch("skin-portrait.jpeg")
        try touch("skin-landscape.jpg")

        try SkinFiles.removeArt(orientation: .portrait, profileFolder: folder)

        XCTAssertEqual(try names(), ["skin-landscape.jpg"])
    }

    /// A profile minted from an edit on the default profile keeps the
    /// skin: moving one button must not make the console art vanish.
    func testCopySkinCarriesArtAndSettingsOnly() throws {
        try touch("skin-portrait.png", "p")
        try touch("skin-landscape.jpg", "l")
        try touch("controls.json", "{}")
        try SkinFiles.writeSettings(SkinSettings(showButtonOutlines: true), profileFolder: folder)
        let target = root.appendingPathComponent("Minted")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        try SkinFiles.copySkin(from: folder, to: target)

        let copied = try FileManager.default.contentsOfDirectory(atPath: target.path).sorted()
        XCTAssertEqual(copied, ["skin-landscape.jpg", "skin-portrait.png", "skin.json"])
        XCTAssertTrue(SkinFiles.readSettings(profileFolder: target).settings.showButtonOutlines)
    }

    func testCopySkinWithoutSkinIsNoOp() throws {
        let target = root.appendingPathComponent("Minted")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        try SkinFiles.copySkin(from: folder, to: target)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testRenameCarriesArt() throws {
        let profilesRoot = root.appendingPathComponent("Profiles")
        let gamesRoot = root.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gamesRoot, withIntermediateDirectories: true)
        let store = LayoutProfileStore(profilesRoot: profilesRoot, gamesRoot: gamesRoot)
        let layout = TouchLayout(dpad: nil, buttons: nil, actionButtons: nil)
        XCTAssertTrue(store.createProfile("Pink", touch: TouchSection(portrait: layout, landscape: nil)))
        _ = try SkinFiles.installArt(
            Data("art".utf8), fileExtension: "png", orientation: .portrait,
            profileFolder: store.profileURL("Pink"))

        XCTAssertTrue(store.renameProfile(from: "Pink", to: "Rose"))

        let found = SkinFiles.artLookup(profileFolder: store.profileURL("Rose"), orientation: .portrait)
        XCTAssertEqual(found.url?.lastPathComponent, "skin-portrait.png")
    }
}

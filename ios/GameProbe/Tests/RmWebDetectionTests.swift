import XCTest

@testable import GameProbe

final class RmWebDetectionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ relativePaths: [String]) throws {
        for path in relativePaths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    func testDesktopMVExportDetectsAsMV() throws {
        try touch([
            "Game.exe",
            "package.json",
            "www/index.html",
            "www/js/rpg_core.js",
        ])
        XCTAssertEqual(RmWebDetection.detect(in: root), .mv)
    }

    func testBrowserMVExportDetectsAsMV() throws {
        try touch([
            "index.html",
            "js/rpg_core.js",
        ])
        XCTAssertEqual(RmWebDetection.detect(in: root), .mv)
    }

    func testMZExportDetectsAsMZ() throws {
        try touch([
            "index.html",
            "js/rmmz_core.js",
        ])
        XCTAssertEqual(RmWebDetection.detect(in: root), .mz)
    }

    func testWwwWrappedMZExportDetectsAsMZ() throws {
        try touch([
            "www/index.html",
            "www/js/rmmz_core.js",
        ])
        XCTAssertEqual(RmWebDetection.detect(in: root), .mz)
    }

    func testMZWinsWhenBothCoreFilesPresent() throws {
        try touch([
            "index.html",
            "js/rpg_core.js",
            "js/rmmz_core.js",
        ])
        XCTAssertEqual(RmWebDetection.detect(in: root), .mz)
    }

    func testPlainWebsiteIsNotClaimed() throws {
        try touch([
            "index.html",
            "js/main.js",
            "css/style.css",
        ])
        XCTAssertNil(RmWebDetection.detect(in: root))
    }

    func testCoreFileWithoutIndexIsNotClaimed() throws {
        try touch([
            "js/rpg_core.js"
        ])
        XCTAssertNil(RmWebDetection.detect(in: root))
    }

    func testRGSSGameIsNotClaimed() throws {
        try touch([
            "Game.ini",
            "Game.exe",
            "Data/Scripts.rxdata",
        ])
        XCTAssertNil(RmWebDetection.detect(in: root))
    }

    func testEmptyDirectoryIsNotClaimed() {
        XCTAssertNil(RmWebDetection.detect(in: root))
    }

    func testIndexHtmlDirectoryIsNotClaimed() throws {
        // A directory literally named index.html must not count as
        // the marker file.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("index.html"),
            withIntermediateDirectories: true)
        try touch(["js/rmmz_core.js"])
        XCTAssertNil(RmWebDetection.detect(in: root))
    }
}

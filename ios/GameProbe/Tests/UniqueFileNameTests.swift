import Foundation
import XCTest

@testable import GameProbe

final class UniqueFileNameTests: XCTestCase {

    // MARK: - numbered

    func testNumberedInsertsSuffixBeforeExtension() {
        XCTAssertEqual(UniqueFileName.numbered("Game.rxdata", index: 2), "Game-2.rxdata")
        XCTAssertEqual(UniqueFileName.numbered("Game.rxdata", index: 17), "Game-17.rxdata")
    }

    func testNumberedUsesOnlyTheLastExtension() {
        XCTAssertEqual(UniqueFileName.numbered("a.b.rxdata", index: 2), "a.b-2.rxdata")
    }

    func testNumberedAppendsToExtensionlessName() {
        XCTAssertEqual(UniqueFileName.numbered("Save", index: 2), "Save-2")
    }

    func testNumberedDotfile() {
        // Foundation treats the leading dot as a hidden-file marker,
        // not an extension separator: pathExtension of ".config" is
        // empty, so the suffix appends to the whole name. Both
        // Darwin Foundation and swift-corelibs agree.
        XCTAssertEqual(UniqueFileName.numbered(".config", index: 2), ".config-2")
    }

    // MARK: - firstAvailable

    func testFirstAvailableReturnsFreePreferredName() {
        let name = UniqueFileName.firstAvailable(preferring: "Game.rxdata") { _ in false }
        XCTAssertEqual(name, "Game.rxdata")
    }

    func testFirstSuffixIsTwo() {
        // Only the preferred name is taken: the numbering starts at
        // 2, never at 1.
        let name = UniqueFileName.firstAvailable(preferring: "Game.rxdata") {
            $0 == "Game.rxdata"
        }
        XCTAssertEqual(name, "Game-2.rxdata")
    }

    func testFirstAvailableSkipsTakenNumberedNames() {
        let taken: Set<String> = ["Game.rxdata", "Game-2.rxdata"]
        let name = UniqueFileName.firstAvailable(preferring: "Game.rxdata") {
            taken.contains($0)
        }
        XCTAssertEqual(name, "Game-3.rxdata")
    }

    func testFirstAvailableUsesCustomNumberedClosure() {
        let taken: Set<String> = ["Game.rxdata", "Game.rxdata.bak-2"]
        let name = UniqueFileName.firstAvailable(
            preferring: "Game.rxdata",
            numbered: { "Game.rxdata.bak-\($0)" }
        ) { taken.contains($0) }
        XCTAssertEqual(name, "Game.rxdata.bak-3")
    }

    func testFirstAvailableFallsBackToUUIDAfter999Probes() {
        // The preferred name is probe 1; indices 2...999 are probes
        // 2...999. After that the UUID fallback returns without
        // another probe.
        var probes = 0
        let name = UniqueFileName.firstAvailable(preferring: "Game.rxdata") { _ in
            probes += 1
            return true
        }
        XCTAssertEqual(probes, 999)
        XCTAssertTrue(name.hasSuffix("-Game.rxdata"))
        let uuidPart = String(name.dropLast("-Game.rxdata".count))
        XCTAssertNotNil(UUID(uuidString: uuidPart))
    }

    func testFallbackIgnoresCustomNumberedClosure() {
        // The UUID fallback derives from the ORIGINAL preferred
        // name, not from the custom numbering scheme.
        var probes = 0
        let name = UniqueFileName.firstAvailable(
            preferring: "Game.rxdata",
            numbered: { "custom-\($0).sav" }
        ) { _ in
            probes += 1
            return true
        }
        XCTAssertEqual(probes, 999)
        XCTAssertTrue(name.hasSuffix("-Game.rxdata"))
        XCTAssertFalse(name.contains("custom-"))
        let uuidPart = String(name.dropLast("-Game.rxdata".count))
        XCTAssertNotNil(UUID(uuidString: uuidPart))
    }

    // MARK: - firstAvailableURL

    func testFirstAvailableURLProbesTheFilesystem() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("UniqueFileNameTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try "x".write(
            to: dir.appendingPathComponent("Game.rxdata"), atomically: true, encoding: .utf8)
        try "x".write(
            to: dir.appendingPathComponent("Game-2.rxdata"), atomically: true, encoding: .utf8)

        let url = UniqueFileName.firstAvailableURL(in: dir, preferring: "Game.rxdata")
        XCTAssertEqual(url.lastPathComponent, "Game-3.rxdata")
        XCTAssertEqual(url.deletingLastPathComponent().path, dir.path)
    }

    func testFirstAvailableURLReturnsPreferredWhenFree() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("UniqueFileNameTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let url = UniqueFileName.firstAvailableURL(in: dir, preferring: "Game.rxdata")
        XCTAssertEqual(url.lastPathComponent, "Game.rxdata")
    }
}

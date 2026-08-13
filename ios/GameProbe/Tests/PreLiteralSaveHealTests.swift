import Foundation
import XCTest

@testable import GameProbe

final class PreLiteralSaveHealTests: XCTestCase {

    private var tempRoot: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempRoot = fm.temporaryDirectory
            .appendingPathComponent("PreLiteralSaveHealTests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ name: String, _ content: String, mtime: Date? = nil, in dir: URL? = nil) -> URL {
        let url = (dir ?? tempRoot).appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    private func names(in dir: URL? = nil) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: (dir ?? tempRoot).path)) ?? [])
    }

    // MARK: - familyBase

    func testFamilyBaseStripsLayers() throws {
        let one = try XCTUnwrap(PreLiteralSaveHeal.familyBase(of: "Game.rxdata.pre-literal.bak"))
        XCTAssertEqual(one.base, "Game.rxdata")
        XCTAssertEqual(one.layers, 1)

        let chained = try XCTUnwrap(
            PreLiteralSaveHeal.familyBase(
                of: "Game.rxdata.bak.pre-literal.bak.pre-literal-3.bak.pre-literal.bak"))
        XCTAssertEqual(chained.base, "Game.rxdata.bak")
        XCTAssertEqual(chained.layers, 3)
    }

    func testFamilyBaseRejectsPlainNames() {
        XCTAssertNil(PreLiteralSaveHeal.familyBase(of: "Game.rxdata"))
        XCTAssertNil(PreLiteralSaveHeal.familyBase(of: "Game.rxdata.bak"))
        // A layer in the middle of a name is not a trailing chain.
        XCTAssertNil(PreLiteralSaveHeal.familyBase(of: "Game.pre-literal.bak.rxdata"))
        // Stripping must never yield an empty base.
        XCTAssertNil(PreLiteralSaveHeal.familyBase(of: ".pre-literal.bak"))
    }

    // MARK: - Promotion policy

    func testNewestMtimeWins() {
        let now = Date()
        write("Game.rxdata.pre-literal.bak.pre-literal.bak", "new", mtime: now)
        write(
            "Game.rxdata.pre-literal.bak.pre-literal.bak.pre-literal.bak.pre-literal.bak",
            "old", mtime: now.addingTimeInterval(-3600))

        let outcome = PreLiteralSaveHeal.heal(directory: tempRoot, fm: fm)

        XCTAssertEqual(outcome.promoted, ["Game.rxdata"])
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: tempRoot.appendingPathComponent("Game.rxdata"), encoding: .utf8),
            "new")
        // The loser stays as the manual override.
        XCTAssertTrue(
            names().contains(
                "Game.rxdata.pre-literal.bak.pre-literal.bak.pre-literal.bak.pre-literal.bak"))
    }

    func testMtimeTieGoesToFewestLayers() {
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        write("Game.rxdata.pre-literal.bak", "joined-late", mtime: stamp)
        write("Game.rxdata.pre-literal.bak.pre-literal.bak.pre-literal.bak", "joined-early", mtime: stamp)

        let outcome = PreLiteralSaveHeal.heal(directory: tempRoot, fm: fm)

        XCTAssertEqual(outcome.promoted, ["Game.rxdata"])
        XCTAssertEqual(
            try String(contentsOf: tempRoot.appendingPathComponent("Game.rxdata"), encoding: .utf8),
            "joined-late")
    }

    func testExistingBaseIsNeverTouched() {
        write("Game.rxdata", "the real save")
        write("Game.rxdata.pre-literal.bak", "stale chain", mtime: Date())

        let outcome = PreLiteralSaveHeal.heal(directory: tempRoot, fm: fm)

        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: tempRoot.appendingPathComponent("Game.rxdata"), encoding: .utf8),
            "the real save")
        XCTAssertTrue(names().contains("Game.rxdata.pre-literal.bak"))
    }

    func testFamiliesHealIndependently() {
        let now = Date()
        write("Game.rxdata.pre-literal.bak", "slot0", mtime: now)
        write("Game1.rxdata.pre-literal.bak.pre-literal.bak", "slot1", mtime: now)
        write("Game.rxdata.bak.pre-literal.bak", "slot0 backup", mtime: now)
        write("config.ini.bak.pre-literal.bak", "not marshal at all", mtime: now)
        write("Settings.dat", "untouched neighbor")

        let outcome = PreLiteralSaveHeal.heal(directory: tempRoot, fm: fm)

        XCTAssertEqual(
            Set(outcome.promoted),
            ["Game.rxdata", "Game1.rxdata", "Game.rxdata.bak", "config.ini.bak"])
        XCTAssertEqual(
            names(),
            ["Game.rxdata", "Game1.rxdata", "Game.rxdata.bak", "config.ini.bak", "Settings.dat"])
    }

    func testHealTreeReachesNestedDataDirs() {
        let org = tempRoot.appendingPathComponent("PKMN Essentials", isDirectory: true)
        let app = org.appendingPathComponent("Nova", isDirectory: true)
        try? fm.createDirectory(at: app, withIntermediateDirectories: true)
        write("Game.rxdata.pre-literal.bak", "nested save", mtime: Date(), in: app)

        let outcome = PreLiteralSaveHeal.healTree(at: tempRoot, fm: fm)

        XCTAssertEqual(outcome.promoted, ["Game.rxdata"])
        XCTAssertEqual(
            try String(contentsOf: app.appendingPathComponent("Game.rxdata"), encoding: .utf8),
            "nested save")
    }

    func testHealIsIdempotent() {
        write("Game.rxdata.pre-literal.bak", "save", mtime: Date())

        XCTAssertEqual(PreLiteralSaveHeal.heal(directory: tempRoot, fm: fm).promoted, ["Game.rxdata"])
        XCTAssertTrue(PreLiteralSaveHeal.heal(directory: tempRoot, fm: fm).isEmpty)
        XCTAssertTrue(PreLiteralSaveHeal.healTree(at: tempRoot, fm: fm).isEmpty)
    }

    func testDirectoriesAreNotCandidates() {
        let trap = tempRoot.appendingPathComponent("Game.rxdata.pre-literal.bak", isDirectory: true)
        try? fm.createDirectory(at: trap, withIntermediateDirectories: true)

        let outcome = PreLiteralSaveHeal.heal(directory: tempRoot, fm: fm)

        XCTAssertTrue(outcome.isEmpty)
        XCTAssertTrue(names().contains("Game.rxdata.pre-literal.bak"))
    }

    func testMissingDirectoryReadsAsEmpty() {
        let missing = tempRoot.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(PreLiteralSaveHeal.heal(directory: missing, fm: fm).isEmpty)
    }

    func testDeviceShapeEndToEnd() {
        // The exact family shape recovered from the field report:
        // interleaved Game.rxdata and Game.rxdata.bak chains, the
        // newest pair carrying the fewest layers.
        let old = Date(timeIntervalSince1970: 1_755_000_000)
        let new = old.addingTimeInterval(85_000)
        write(
            "Game.rxdata.pre-literal.bak.pre-literal.bak.pre-literal.bak.pre-literal.bak"
                + ".pre-literal.bak.pre-literal.bak.pre-literal.bak",
            "yesterday", mtime: old)
        write("Game.rxdata.pre-literal.bak.pre-literal.bak", "today", mtime: new)
        write(
            "Game.rxdata.bak.pre-literal.bak.pre-literal.bak.pre-literal.bak.pre-literal.bak"
                + ".pre-literal.bak.pre-literal.bak.pre-literal.bak",
            "yesterday bak", mtime: old)
        write("Game.rxdata.bak.pre-literal.bak.pre-literal.bak", "today bak", mtime: new)

        let outcome = PreLiteralSaveHeal.heal(directory: tempRoot, fm: fm)

        XCTAssertEqual(Set(outcome.promoted), ["Game.rxdata", "Game.rxdata.bak"])
        XCTAssertEqual(
            try String(contentsOf: tempRoot.appendingPathComponent("Game.rxdata"), encoding: .utf8),
            "today")
        XCTAssertEqual(
            try String(contentsOf: tempRoot.appendingPathComponent("Game.rxdata.bak"), encoding: .utf8),
            "today bak")
    }
}

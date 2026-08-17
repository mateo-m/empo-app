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
        // Failure fixtures drop permissions. Restore them so the
        // temp root always deletes cleanly.
        try? GameTreeUpdate.normalizeOwnerWritable(at: tempRoot)
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

    func testPromotionOrderingTable() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        func candidate(_ name: String, _ offset: TimeInterval, _ layers: Int)
            -> PreLiteralSaveHeal.Candidate
        {
            .init(name: name, modificationDate: base.addingTimeInterval(offset), layerCount: layers)
        }

        // Newest mtime beats fewer layers and smaller names.
        XCTAssertEqual(
            PreLiteralSaveHeal.promotion(among: [
                candidate("a", 0, 1),
                candidate("z", 60, 9),
            ])?.name,
            "z")
        // Equal mtime: fewest layers wins even against a smaller name.
        XCTAssertEqual(
            PreLiteralSaveHeal.promotion(among: [
                candidate("a", 0, 3),
                candidate("z", 0, 2),
            ])?.name,
            "z")
        // Equal mtime and layers: lexicographically first wins.
        XCTAssertEqual(
            PreLiteralSaveHeal.promotion(among: [
                candidate("b", 0, 2),
                candidate("a", 0, 2),
            ])?.name,
            "a")
        XCTAssertNil(PreLiteralSaveHeal.promotion(among: []))
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

        // Families promote in sorted-base order, deterministically.
        XCTAssertEqual(
            outcome.promoted,
            ["Game.rxdata", "Game.rxdata.bak", "Game1.rxdata", "config.ini.bak"])
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(
            names(),
            ["Game.rxdata", "Game1.rxdata", "Game.rxdata.bak", "config.ini.bak", "Settings.dat"])
        XCTAssertEqual(
            try String(contentsOf: tempRoot.appendingPathComponent("config.ini.bak"), encoding: .utf8),
            "not marshal at all")
    }

    func testFailedPromotionIsReportedAndRetriable() throws {
        let locked = tempRoot.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        write("Game.rxdata.pre-literal.bak", "save", mtime: Date(), in: locked)
        // A read-only directory rejects the rename.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        let outcome = PreLiteralSaveHeal.heal(directory: locked, fm: fm)

        XCTAssertEqual(outcome.failures, ["Game.rxdata.pre-literal.bak"])
        XCTAssertTrue(outcome.promoted.isEmpty)
        XCTAssertFalse(outcome.isEmpty)

        // Unlock and retry: the same call must now succeed - the
        // launch-time heal relies on failed promotions staying
        // retriable.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        let retry = PreLiteralSaveHeal.heal(directory: locked, fm: fm)
        XCTAssertEqual(retry.promoted, ["Game.rxdata"])
        XCTAssertEqual(
            try String(contentsOf: locked.appendingPathComponent("Game.rxdata"), encoding: .utf8),
            "save")
    }

    func testHealTreeReportsRootRelativePaths() {
        let org = tempRoot.appendingPathComponent("PKMN Essentials", isDirectory: true)
        let app = org.appendingPathComponent("Nova", isDirectory: true)
        let anil = tempRoot.appendingPathComponent("Anil", isDirectory: true)
        try? fm.createDirectory(at: app, withIntermediateDirectories: true)
        try? fm.createDirectory(at: anil, withIntermediateDirectories: true)
        write("Game.rxdata.pre-literal.bak", "nested save", mtime: Date(), in: app)
        write("Game2.rxdata.pre-literal.bak", "anil save", mtime: Date(), in: anil)
        write("Root.rxdata.pre-literal.bak", "root-level", mtime: Date())

        let outcome = PreLiteralSaveHeal.healTree(at: tempRoot, fm: fm)

        // Root entries first, then subdirectories in sorted order,
        // every path relative to the walked root.
        XCTAssertEqual(
            outcome.promoted,
            [
                "Root.rxdata",
                "Anil/Game2.rxdata",
                "PKMN Essentials/Nova/Game.rxdata",
            ])
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: app.appendingPathComponent("Game.rxdata"), encoding: .utf8),
            "nested save")
    }

    func testGroupedByDirectory() {
        let groups = PreLiteralSaveHeal.groupedByDirectory([
            "Root.rxdata",
            "Nova/Game.rxdata",
            "Anil/Game2.rxdata",
            "Nova/Game1.rxdata",
            "PKMN Essentials/Nova/Game.rxdata",
        ])

        // The CONTAINING directory is the key: an org-nested game
        // groups under its full path, never under the org alone.
        XCTAssertEqual(
            groups.map(\.directory),
            ["Anil", "Nova", "PKMN Essentials/Nova"])
        XCTAssertEqual(groups[0].files, ["Game2.rxdata"])
        XCTAssertEqual(groups[1].files, ["Game.rxdata", "Game1.rxdata"])
        XCTAssertEqual(groups[2].files, ["Game.rxdata"])
        // The root-level path has no directory and is dropped.
        XCTAssertTrue(PreLiteralSaveHeal.groupedByDirectory(["Root.rxdata"]).isEmpty)
    }

    func testHealTreeSkipsDirectorySymlinks() throws {
        let real = tempRoot.appendingPathComponent("Nova", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        write("Game.rxdata.pre-literal.bak", "save", mtime: Date(), in: real)
        // A cycle: Data/Nova/loop -> Data. Following it would
        // recurse forever.
        try fm.createSymbolicLink(
            at: real.appendingPathComponent("loop"),
            withDestinationURL: tempRoot)

        let outcome = PreLiteralSaveHeal.healTree(at: tempRoot, fm: fm)

        XCTAssertEqual(outcome.promoted, ["Nova/Game.rxdata"])
        XCTAssertTrue(outcome.failures.isEmpty)
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

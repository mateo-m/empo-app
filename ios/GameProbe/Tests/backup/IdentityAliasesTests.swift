import Foundation
import XCTest

@testable import GameProbe

/// The alias store of SPEC 4.3, `EmpoState/identity_aliases.json`.
final class IdentityAliasesTests: XCTestCase {

    private var stateDirectory: URL!

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-aliases-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("EmpoState", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDirectory.deletingLastPathComponent())
    }

    // MARK: - Both places, per 4.3

    func testAnAttachWritesTheAliasToTheStoreAndToTheManifest() throws {
        let game = GameIdentity(folderName: "Fixture Quest 2")
        let snapshot = SnapshotIdentity(containerFolderName: "Fixture Quest")
        let alias = try XCTUnwrap(GameIdentityMatch.alias(attaching: snapshot, to: game))

        var store = try IdentityAliases.load(from: stateDirectory)
        XCTAssertTrue(store.add(alias, forFolderName: game.folderName))
        try store.save(to: stateDirectory)

        // The first place: the game's own `EmpoState/`.
        let reloaded = try IdentityAliases.load(from: stateDirectory)
        XCTAssertEqual(reloaded.aliases, ["Fixture Quest"])

        // The second place: the header of every later manifest.
        let manifest = SnapshotManifest(
            mode: .slim,
            containerFolderName: game.folderName,
            identityAlias: reloaded.manifestAlias)
        XCTAssertEqual(manifest.identityAlias, "Fixture Quest")

        // The next match asks no second question.
        let matched = reloaded.identity(forFolderName: game.folderName)
        XCTAssertTrue(GameIdentityMatch.matches(snapshot, matched))
        XCTAssertNil(GameIdentityMatch.alias(attaching: snapshot, to: matched))
    }

    func testASecondAttachOfTheSameNameChangesNothing() {
        var store = IdentityAliases(aliases: ["Fixture Quest"])

        XCTAssertFalse(store.add("Fixture Quest", forFolderName: "Fixture Quest 2"))
        XCTAssertFalse(store.add("fixture quest", forFolderName: "Fixture Quest 2"))
        XCTAssertEqual(store.aliases, ["Fixture Quest"])
    }

    func testAnAliasEqualToTheFolderNameIsNotRecorded() {
        var store = IdentityAliases()

        XCTAssertFalse(store.add("Fixture Quest", forFolderName: "Fixture Quest"))
        XCTAssertTrue(store.aliases.isEmpty)
    }

    func testTwoAttachesRecordTwoAliasesOldestFirst() {
        var store = IdentityAliases()

        XCTAssertTrue(store.add("Fixture Quest", forFolderName: "Fixture Quest 3"))
        XCTAssertTrue(store.add("Fixture Quest 2", forFolderName: "Fixture Quest 3"))

        XCTAssertEqual(store.aliases, ["Fixture Quest", "Fixture Quest 2"])
        XCTAssertEqual(store.manifestAlias, "Fixture Quest 2")
        XCTAssertEqual(
            store.identity(forFolderName: "Fixture Quest 3").names,
            ["Fixture Quest 3", "Fixture Quest", "Fixture Quest 2"])
    }

    // MARK: - The file

    func testAMergeKeepsTheRestoredAliasesAndAddsTheLocalOnesAfterThem() {
        var restored = IdentityAliases(aliases: ["Old Quest"])
        let local = IdentityAliases(aliases: ["Old Quest", "Fixture Quest"])

        XCTAssertTrue(restored.merge(local, forFolderName: "Fixture Quest 2"))
        XCTAssertEqual(restored.aliases, ["Old Quest", "Fixture Quest"])
        XCTAssertEqual(restored.manifestAlias, "Fixture Quest")
        XCTAssertFalse(restored.merge(local, forFolderName: "Fixture Quest 2"))
    }

    func testAMissingFileGivesTheEmptyStore() throws {
        XCTAssertEqual(try IdentityAliases.load(from: stateDirectory).aliases, [])
    }

    func testADamagedFileKeepsACopyAndGivesTheEmptyStore() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
        let damaged = Data("{\"aliases\":".utf8)
        try damaged.write(to: stateDirectory.appendingPathComponent(IdentityAliases.fileName))

        XCTAssertEqual(try IdentityAliases.load(from: stateDirectory).aliases, [])
        let kept = try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)
            .filter { $0.hasPrefix(IdentityAliases.fileName + ".damaged-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: stateDirectory.appendingPathComponent(try XCTUnwrap(kept.first))),
            damaged)
    }

    func testTheFileKeepsAFieldThisBuildDoesNotKnow() throws {
        let written = Data(
            """
            { "version": 2, "aliases": ["Fixture Quest"], "attachedAt": "later" }
            """.utf8)
        try FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
        try written.write(
            to: stateDirectory.appendingPathComponent(IdentityAliases.fileName))

        var store = try IdentityAliases.load(from: stateDirectory)
        XCTAssertEqual(store.version, 2)
        XCTAssertEqual(store.aliases, ["Fixture Quest"])

        store.add("Fixture Quest 2", forFolderName: "Fixture Quest 3")
        try store.save(to: stateDirectory)

        let fields = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(
                contentsOf: stateDirectory.appendingPathComponent(IdentityAliases.fileName)))
        XCTAssertEqual(fields["attachedAt"]?.string, "later")
        XCTAssertEqual(fields["version"]?.int, 2)
    }
}

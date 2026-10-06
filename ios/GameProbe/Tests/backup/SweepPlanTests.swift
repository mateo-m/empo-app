import Foundation
import XCTest

@testable import GameProbe

final class SweepPlanTests: XCTestCase {

    /// The clock is a parameter, so the answer never depends on the
    /// day the suite runs.
    private let now = Date(timeIntervalSince1970: 1_777_593_600)  // 2026-05-01T00:00:00Z

    private func hash(_ seed: String) -> String {
        ContentHash.hex(ofUTF8: seed)
    }

    private func blob(_ seed: String, daysOld: Double) -> BlobObject {
        BlobObject(
            path: BackupKeys.blobPath(hash: hash(seed), fanOutWidth: 2),
            modifiedAt: now.addingTimeInterval(-daysOld * 86_400))
    }

    private func manifest(
        naming seeds: [String], chunks: [String] = []
    ) -> SnapshotManifest {
        SnapshotManifest(
            mode: .slim,
            containerFolderName: "Yume Nikki",
            entries: seeds.enumerated().map { index, seed in
                SnapshotManifest.Entry(
                    root: .container,
                    path: "Game/Save\(index).rvdata2",
                    size: 2048,
                    modifiedAt: now,
                    hash: hash(seed),
                    compression: .zlib,
                    chunks: chunks.isEmpty ? nil : chunks.map(hash))
            })
    }

    // MARK: - The 7-day margin

    func testAYoungOrphanStaysAndAnOldOrphanGoes() {
        let young = blob("young", daysOld: 6)
        let old = blob("old", daysOld: 8)

        let deletions = SweepPlan.blobsToDelete(
            manifests: [manifest(naming: ["referenced"])],
            blobs: [young, old],
            now: now)

        XCTAssertEqual(deletions, [old.path])
    }

    func testTheMarginIsSevenDays() {
        XCTAssertEqual(SweepPlan.margin, 7 * 86_400)

        let justInside = blob("inside", daysOld: 6.99)
        let justOutside = blob("outside", daysOld: 7.01)

        XCTAssertEqual(
            SweepPlan.blobsToDelete(
                manifests: [], blobs: [justInside, justOutside], now: now),
            [justOutside.path])
    }

    func testABlobWithATimeAheadOfTheClockStays() {
        let future = blob("future", daysOld: -3)

        XCTAssertTrue(
            SweepPlan.blobsToDelete(manifests: [], blobs: [future], now: now).isEmpty)
    }

    // MARK: - The mark

    func testAReferencedBlobStaysWhateverItsAge() {
        let referenced = blob("referenced", daysOld: 400)

        XCTAssertTrue(
            SweepPlan.blobsToDelete(
                manifests: [manifest(naming: ["referenced"])],
                blobs: [referenced],
                now: now
            ).isEmpty)
    }

    func testTheMarkReadsEveryManifestOfTheNamespace() {
        let first = blob("first", daysOld: 90)
        let second = blob("second", daysOld: 90)
        let orphan = blob("orphan", daysOld: 90)

        let deletions = SweepPlan.blobsToDelete(
            manifests: [manifest(naming: ["first"]), manifest(naming: ["second"])],
            blobs: [first, second, orphan],
            now: now)

        XCTAssertEqual(deletions, [orphan.path])
    }

    /// The reserved chunk list of 5.5 counts as a reference. Version
    /// 1 never writes one, but a marker that ignored it would delete
    /// the blobs of a version it does not understand.
    func testAChunkListCountsAsAReference() {
        let chunk = blob("chunk-a", daysOld: 90)
        let orphan = blob("orphan", daysOld: 90)

        let deletions = SweepPlan.blobsToDelete(
            manifests: [manifest(naming: ["whole"], chunks: ["chunk-a"])],
            blobs: [chunk, orphan],
            now: now)

        XCTAssertEqual(deletions, [orphan.path])
    }

    func testReferencedHashesGathersEveryEntryAndChunk() {
        let hashes = SweepPlan.referencedHashes(
            in: [manifest(naming: ["one", "two"], chunks: ["chunk-a", "chunk-b"])])

        XCTAssertEqual(
            hashes,
            Set([hash("one"), hash("two"), hash("chunk-a"), hash("chunk-b")]))
    }

    // MARK: - What the sweep never touches

    func testAPathThatNamesNoHashIsNeverDeleted() {
        let old = now.addingTimeInterval(-400 * 86_400)
        let strangers = [
            "games/\(hash("game"))/20260101T000000Z-0a1b2c.json",
            "writer.json",
            // A provider or a desktop tool drops these beside the
            // blobs. None of them names a hash.
            "blobs/ab/.DS_Store",
            "blobs/ab/Thumbs.db",
            "blobs/ab/\(hash("elsewhere"))",
            "blobs/ab/\(hash("upper").uppercased())",
            "blobs/",
        ].map { BlobObject(path: $0, modifiedAt: old) }

        XCTAssertTrue(
            SweepPlan.blobsToDelete(manifests: [], blobs: strangers, now: now).isEmpty)
    }

    func testTheDeletionsComeBackSortedByPath() {
        let blobs = ["e", "c", "a", "d", "b"].map { blob($0, daysOld: 30) }

        let deletions = SweepPlan.blobsToDelete(manifests: [], blobs: blobs, now: now)

        XCTAssertEqual(deletions.count, 5)
        XCTAssertEqual(deletions, deletions.sorted())
    }

    func testAnEmptyNamespaceDeletesNothing() {
        XCTAssertTrue(SweepPlan.blobsToDelete(manifests: [], blobs: [], now: now).isEmpty)
    }
}

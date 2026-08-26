import Foundation
import XCTest

@testable import GameProbe

final class BackupKeysTests: XCTestCase {

    /// A title with unicode and a space, and the digest of its UTF-8
    /// bytes, computed away from this code.
    private let unicodeName = "ゆめにっき Yume Nikki"
    private let unicodeNameDigest =
        "360dee6841d5d32148f5acd636ee1b2b924aed1f45f22a80e89feaca5452a2a4"

    // MARK: - The game key

    func testTheGameKeyIsTheDigestOfTheContainerFolderName() {
        XCTAssertEqual(
            BackupKeys.gameKey(containerFolderName: unicodeName), unicodeNameDigest)
    }

    /// Dropbox folds case, so two titles that differ only in case
    /// must not reach one folder.
    func testTwoNamesThatDifferOnlyInCaseGetDifferentKeys() {
        let lower = BackupKeys.gameKey(containerFolderName: "yume nikki")
        let upper = BackupKeys.gameKey(containerFolderName: "Yume Nikki")
        XCTAssertNotEqual(lower, upper)
    }

    func testTheGameKeyHoldsNoCharacterAProviderRejects() {
        let key = BackupKeys.gameKey(containerFolderName: unicodeName)
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { "0123456789abcdef".contains($0) })
    }

    // MARK: - The snapshot id

    func testASnapshotIdCarriesTheFormOfSection52() {
        let date = Date(timeIntervalSince1970: 1_777_593_600)  // 2026-05-01T00:00:00Z
        XCTAssertEqual(
            BackupKeys.snapshotId(date: date, suffix: "0a1b2c"),
            "20260501T000000Z-0a1b2c")
    }

    func testSnapshotIdsSortByNameAcrossADayBoundary() {
        let boundary = Date(timeIntervalSince1970: 1_777_593_600)  // midnight UTC
        let before = BackupKeys.snapshotId(
            date: boundary.addingTimeInterval(-1), suffix: "ffffff")
        let after = BackupKeys.snapshotId(date: boundary, suffix: "000000")

        XCTAssertEqual(before, "20260430T235959Z-ffffff")
        XCTAssertEqual(after, "20260501T000000Z-000000")
        XCTAssertLessThan(before, after)
        XCTAssertEqual([after, before].sorted(), [before, after])
    }

    func testSnapshotIdsSortByNameAcrossAYearBoundary() {
        let boundary = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01T00:00:00Z
        let before = BackupKeys.snapshotId(
            date: boundary.addingTimeInterval(-1), suffix: "ffffff")
        let after = BackupKeys.snapshotId(date: boundary, suffix: "000000")

        XCTAssertEqual(before, "20251231T235959Z-ffffff")
        XCTAssertEqual(after, "20260101T000000Z-000000")
        XCTAssertLessThan(before, after)
    }

    /// Name order and time order are the same order over a stream
    /// that crosses both boundaries.
    func testNameOrderMatchesTimeOrderOverAStream() {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let dates = (0..<40).map { start.addingTimeInterval(Double($0) * 43_200 - 86_400 * 3) }
        let ids = dates.enumerated().map {
            BackupKeys.snapshotId(date: $1, suffix: String(format: "%06x", $0))
        }
        XCTAssertEqual(ids.shuffled().sorted(), ids)
    }

    func testASnapshotIdGivesItsUTCSecondBack() {
        let date = Date(timeIntervalSince1970: 1_777_593_723)
        let id = BackupKeys.snapshotId(date: date, suffix: "abc123")
        XCTAssertEqual(BackupKeys.timestamp(ofSnapshotId: id), date)
    }

    func testAnIdOfAnotherFormCarriesNoTimestamp() {
        XCTAssertNil(BackupKeys.timestamp(ofSnapshotId: ""))
        XCTAssertNil(BackupKeys.timestamp(ofSnapshotId: "20260501T000000Z"))
        XCTAssertNil(BackupKeys.timestamp(ofSnapshotId: "20260501T000000Z-0A1B2C"))
        XCTAssertNil(BackupKeys.timestamp(ofSnapshotId: "20260501-000000Z-0a1b2c"))
        XCTAssertNil(BackupKeys.timestamp(ofSnapshotId: "2026050xT000000Z-0a1b2c"))
    }

    func testAGeneratedSnapshotIdParsesBack() {
        let date = Date(timeIntervalSince1970: 1_777_593_723)
        let id = BackupKeys.makeSnapshotId(date: date)
        XCTAssertEqual(BackupKeys.timestamp(ofSnapshotId: id), date)
    }

    // MARK: - The blob path

    func testABlobPathFansOutByTheWidth() {
        let hash = String(repeating: "a", count: 62) + "bc"
        XCTAssertEqual(
            BackupKeys.blobPath(hash: hash, fanOutWidth: 2), "blobs/aa/\(hash)")
        XCTAssertEqual(
            BackupKeys.blobPath(hash: hash, fanOutWidth: 3), "blobs/aaa/\(hash)")
        XCTAssertEqual(
            BackupKeys.blobPath(hash: hash, fanOutWidth: 0), "blobs/\(hash)")
    }

    func testTheDescriptorDecidesTheFanOut() {
        let hash = ContentHash.hex(ofUTF8: "blob")
        XCTAssertEqual(
            FormatDescriptor().blobPath(hash: hash),
            BackupKeys.blobPath(hash: hash, fanOutWidth: 2))
    }

    func testABlobPathGivesItsHashBack() {
        let hash = ContentHash.hex(ofUTF8: "blob")

        XCTAssertEqual(
            BackupKeys.blobHash(
                atPath: BackupKeys.blobPath(hash: hash, fanOutWidth: 2)), hash)
        XCTAssertEqual(
            BackupKeys.blobHash(
                atPath: BackupKeys.blobPath(hash: hash, fanOutWidth: 3)), hash)
        XCTAssertEqual(
            BackupKeys.blobHash(
                atPath: BackupKeys.blobPath(hash: hash, fanOutWidth: 0)), hash)
    }

    /// The sweep deletes what `blobHash` names, so anything that is
    /// not a blob must come back `nil`.
    func testAPathThatIsNotABlobPathNamesNoHash() {
        let hash = ContentHash.hex(ofUTF8: "blob")
        let cases = [
            "games/\(hash)/x.json",
            "blobs",
            "blobs/",
            "blobs/ab/.DS_Store",
            "blobs/ab/Thumbs.db",
            // The fan-out folder does not start the hash.
            "blobs/zz/\(hash)",
            // Upper case is not the naming rule.
            "blobs/AB/\(hash.uppercased())",
            // Deeper than the layout of 5.1.
            "blobs/ab/cd/\(hash)",
        ]
        for path in cases {
            XCTAssertNil(BackupKeys.blobHash(atPath: path), path)
        }
    }

    // MARK: - The namespace id

    func testANamespaceIdIsHexAndFreshEachTime() {
        let ids = (0..<50).map { _ in BackupKeys.makeNamespaceId() }
        for id in ids {
            XCTAssertEqual(id.count, 32)
            XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
        }
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

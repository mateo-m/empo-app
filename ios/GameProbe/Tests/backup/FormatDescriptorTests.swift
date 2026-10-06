import Foundation
import XCTest

@testable import GameProbe

final class FormatDescriptorTests: XCTestCase {

    // MARK: - Read and write

    func testTheVersion1DescriptorReadsFromTheFixture() throws {
        let descriptor = try FormatDescriptor.decode(
            json: BackupFixtures.data("format-v1.json"))

        XCTAssertEqual(descriptor.formatVersion, 1)
        XCTAssertEqual(descriptor.hashFunction, "sha-256")
        XCTAssertEqual(descriptor.blobNaming, "hash-hex")
        XCTAssertEqual(descriptor.fanOutWidth, 2)
    }

    func testWhatThisBuildWritesMatchesTheFixture() throws {
        let written = try FormatDescriptor().jsonData()
        let fixture = try BackupFixtures.data("format-v1.json")

        XCTAssertEqual(
            try FormatDescriptor.decode(json: written),
            try FormatDescriptor.decode(json: fixture))
    }

    func testADescriptorRoundTrips() throws {
        let descriptor = FormatDescriptor(
            formatVersion: 2, hashFunction: "blake3-keyed", blobNaming: "hash-hex",
            fanOutWidth: 3)
        let back = try FormatDescriptor.decode(json: descriptor.jsonData())
        XCTAssertEqual(back, descriptor)
    }

    // MARK: - The read-only test of 5.16

    func testAVersion1TargetIsWritable() throws {
        let access = FormatDescriptor.targetAccess(
            formatJSON: try BackupFixtures.data("format-v1.json"))

        XCTAssertEqual(access, .readWrite)
        XCTAssertTrue(access.allowsWrite)
        XCTAssertTrue(access.allowsPrune)
    }

    func testANewerTargetIsReadOnly() throws {
        let access = FormatDescriptor.targetAccess(
            formatJSON: try BackupFixtures.data("format-v2.json"))

        XCTAssertEqual(access, .readOnly(.newerFormatVersion(2)))
        XCTAssertFalse(access.allowsWrite)
        XCTAssertFalse(access.allowsPrune)
    }

    /// A device that cannot parse `format.json` treats the whole
    /// target as read-only, per 5.16.
    func testATargetWithABrokenFormatFileIsReadOnly() throws {
        let access = FormatDescriptor.targetAccess(
            formatJSON: try BackupFixtures.data("format-broken.json"))

        XCTAssertEqual(access, .readOnly(.unreadableFormat))
        XCTAssertFalse(access.allowsWrite)
        XCTAssertFalse(access.allowsPrune)
    }

    func testATargetWithNoFormatFileIsReadOnly() {
        XCTAssertEqual(
            FormatDescriptor.targetAccess(formatJSON: nil),
            .readOnly(.unreadableFormat))
    }

    /// Version 1 fixes the hash function, the naming rule, and the
    /// width. A file that names version 1 and something else is not a
    /// version 1 file.
    func testAVersion1FileThatNamesAnotherLayoutIsUnreadable() throws {
        let cases = [
            FormatDescriptor(hashFunction: "blake3"),
            FormatDescriptor(blobNaming: "hash-base32"),
            FormatDescriptor(fanOutWidth: 3),
            FormatDescriptor(formatVersion: 0),
        ]
        for descriptor in cases {
            XCTAssertEqual(
                FormatDescriptor.targetAccess(formatJSON: try descriptor.jsonData()),
                .readOnly(.unreadableFormat),
                "\(descriptor)")
        }
    }

    // MARK: - The namespace answers for itself

    func testAVersion1NamespaceIsWritable() {
        XCTAssertEqual(
            FormatDescriptor.namespaceAccess(manifestFormatVersion: 1), .readWrite)
    }

    func testANamespaceOfANewerVersionIsReadOnly() {
        let access = FormatDescriptor.namespaceAccess(manifestFormatVersion: 2)
        XCTAssertEqual(access, .readOnly(.newerFormatVersion(2)))
    }

    func testANamespaceOfAVersionBelowOneIsUnreadable() {
        XCTAssertEqual(
            FormatDescriptor.namespaceAccess(manifestFormatVersion: 0),
            .readOnly(.unreadableFormat))
    }

    /// A version 1 file that declares another width goes read-only,
    /// and `blobPath` still obeys the width it declares, per 15.3.
    func testAReadOnlyDescriptorStillFansOutTheWayItSaysItDoes() throws {
        let descriptor = FormatDescriptor(fanOutWidth: 3)
        let hash = ContentHash.hex(ofUTF8: "blob")

        XCTAssertEqual(
            FormatDescriptor.targetAccess(formatJSON: try descriptor.jsonData()),
            .readOnly(.unreadableFormat))
        XCTAssertEqual(
            descriptor.blobPath(hash: hash), "blobs/\(hash.prefix(3))/\(hash)")
    }
}

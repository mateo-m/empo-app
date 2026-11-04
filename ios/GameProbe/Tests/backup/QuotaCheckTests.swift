import Foundation
import XCTest

@testable import GameProbe

/// The room a target has for a run, per SPEC 5.14.
final class QuotaCheckTests: XCTestCase {

    private func reading(used: Int64, limit: Int64?) -> QuotaReading {
        QuotaReading(usedBytes: used, limitBytes: limit)
    }

    func testTheSmallerRoomGoverns() {
        XCTAssertEqual(
            QuotaCheck.freeBytes(
                reading: reading(used: 0, limit: 1_000), capBytes: 400, storedBytes: 0),
            400)
        XCTAssertEqual(
            QuotaCheck.freeBytes(
                reading: reading(used: 0, limit: 300), capBytes: 400, storedBytes: 0),
            300)
    }

    func testTheCapCountsEmposOwnBytesAndNotTheAccount() {
        // The account holds 9,000 bytes of other files. Empo holds
        // 100, so a cap of 400 leaves 300.
        XCTAssertEqual(
            QuotaCheck.freeBytes(
                reading: reading(used: 9_100, limit: 100_000), capBytes: 400,
                storedBytes: 100),
            300)
    }

    func testACapAloneGoverns() {
        XCTAssertEqual(
            QuotaCheck.freeBytes(
                reading: reading(used: 0, limit: nil), capBytes: 400, storedBytes: 150),
            250)
    }

    func testNoNumberGovernsWhenNeitherStatesOne() {
        XCTAssertNil(
            QuotaCheck.freeBytes(
                reading: reading(used: 0, limit: nil), capBytes: nil, storedBytes: 0))
        XCTAssertNil(QuotaCheck.freeBytes(reading: nil, capBytes: nil, storedBytes: 0))
    }

    func testFreeBytesNeverGoesBelowZero() {
        XCTAssertEqual(
            QuotaCheck.freeBytes(
                reading: reading(used: 900, limit: 500), capBytes: nil, storedBytes: 0),
            0)
        XCTAssertEqual(
            QuotaCheck.freeBytes(reading: nil, capBytes: 100, storedBytes: 300), 0)
    }

    func testARunThatFitsIsNotRefused() {
        XCTAssertNil(
            QuotaCheck.shortfall(
                pendingBytes: 100, reading: reading(used: 0, limit: 500), capBytes: nil,
                storedBytes: 0))
    }

    func testARunThatCannotFitNamesTheShortfall() {
        let shortfall = QuotaCheck.shortfall(
            pendingBytes: 700, reading: reading(used: 100, limit: 500), capBytes: nil,
            storedBytes: 0)

        XCTAssertEqual(shortfall?.neededBytes, 700)
        XCTAssertEqual(shortfall?.freeBytes, 400)
        XCTAssertEqual(shortfall?.missingBytes, 300)
    }

    func testTheCapRefusesARunTheProviderWouldTake() {
        XCTAssertNil(
            QuotaCheck.shortfall(
                pendingBytes: 300, reading: reading(used: 0, limit: 10_000), capBytes: nil,
                storedBytes: 0))
        XCTAssertEqual(
            QuotaCheck.shortfall(
                pendingBytes: 300, reading: reading(used: 0, limit: 10_000), capBytes: 200,
                storedBytes: 0)?
                .missingBytes,
            100)
    }

    func testTheCapRefusesARunOnATargetWithNoSpaceQuery() {
        XCTAssertEqual(
            QuotaCheck.shortfall(pendingBytes: 700, reading: nil, capBytes: 100, storedBytes: 0)?
                .missingBytes,
            600)
    }

    func testATargetWithNoSpaceQueryAndNoCapRefusesNothing() {
        XCTAssertNil(
            QuotaCheck.shortfall(pendingBytes: 700, reading: nil, capBytes: nil, storedBytes: 0))
    }

    func testTheBlockedLineNamesTheMissingBytesInHumanUnits() {
        let line = QuotaCheck.blockedLine(
            QuotaCheck.Shortfall(neededBytes: 2_500_000_000, freeBytes: 400_000_000))

        // ByteCountFormatter follows the region: "2,1 GB" on a Mac set to France,
        // "2.1 GB" on the Linux runner.
        let missing = ByteCountFormatter.string(fromByteCount: 2_100_000_000, countStyle: .file)
        XCTAssertEqual(line, "This location needs \(missing) more space for the next backup.")
    }
}

import Foundation
import XCTest

@testable import GameProbe

/// The room a target has for a run, per SPEC 5.14.
final class QuotaCheckTests: XCTestCase {

    private func reading(used: Int64, limit: Int64?) -> QuotaReading {
        QuotaReading(usedBytes: used, limitBytes: limit)
    }

    func testTheSmallerOfTheLimitAndTheCapGoverns() {
        XCTAssertEqual(
            QuotaCheck.effectiveLimit(reading: reading(used: 0, limit: 1_000), capBytes: 400),
            400)
        XCTAssertEqual(
            QuotaCheck.effectiveLimit(reading: reading(used: 0, limit: 300), capBytes: 400),
            300)
    }

    func testACapAloneGoverns() {
        XCTAssertEqual(
            QuotaCheck.effectiveLimit(reading: reading(used: 0, limit: nil), capBytes: 400),
            400)
    }

    func testNoNumberGovernsWhenNeitherStatesOne() {
        XCTAssertNil(
            QuotaCheck.effectiveLimit(reading: reading(used: 0, limit: nil), capBytes: nil))
        XCTAssertNil(QuotaCheck.effectiveLimit(reading: nil, capBytes: nil))
    }

    func testFreeBytesNeverGoesBelowZero() {
        XCTAssertEqual(
            QuotaCheck.freeBytes(reading: reading(used: 900, limit: 500), capBytes: nil), 0)
    }

    func testARunThatFitsIsNotRefused() {
        XCTAssertNil(
            QuotaCheck.shortfall(
                pendingBytes: 100, reading: reading(used: 0, limit: 500), capBytes: nil))
    }

    func testARunThatCannotFitNamesTheShortfall() {
        let shortfall = QuotaCheck.shortfall(
            pendingBytes: 700, reading: reading(used: 100, limit: 500), capBytes: nil)

        XCTAssertEqual(shortfall?.neededBytes, 700)
        XCTAssertEqual(shortfall?.freeBytes, 400)
        XCTAssertEqual(shortfall?.missingBytes, 300)
    }

    func testTheCapRefusesARunTheProviderWouldTake() {
        XCTAssertNil(
            QuotaCheck.shortfall(
                pendingBytes: 300, reading: reading(used: 0, limit: 10_000), capBytes: nil))
        XCTAssertEqual(
            QuotaCheck.shortfall(
                pendingBytes: 300, reading: reading(used: 0, limit: 10_000), capBytes: 200)?
                .missingBytes,
            100)
    }

    func testAProviderThatAnswersNoSpaceQueryRefusesNothing() {
        XCTAssertNil(QuotaCheck.shortfall(pendingBytes: 700, reading: nil, capBytes: 100))
    }

    func testTheBlockedLineNamesTheMissingBytes() {
        let line = QuotaCheck.blockedLine(
            QuotaCheck.Shortfall(neededBytes: 700, freeBytes: 400))

        XCTAssertTrue(line.contains("300"))
    }
}

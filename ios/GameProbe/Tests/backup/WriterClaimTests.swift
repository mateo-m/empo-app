import Foundation
import XCTest

@testable import GameProbe

/// The writer claim of SPEC 5.12.
final class WriterClaimTests: XCTestCase {

    private let claimedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func claim(
        deviceId: String = "device-a", namespaceId: String = "ns-1"
    ) -> WriterClaim {
        WriterClaim(
            namespaceId: namespaceId, deviceId: deviceId,
            deviceName: "iPhone", claimedAt: claimedAt)
    }

    func testAnEmptyLocationIsClaimed() {
        XCTAssertEqual(
            WriterClaimCheck.decide(found: nil, deviceId: "device-a", namespaceId: "ns-1"),
            .claim)
    }

    func testOurOwnClaimProceeds() {
        XCTAssertEqual(
            WriterClaimCheck.decide(
                found: claim(), deviceId: "device-a", namespaceId: "ns-1"),
            .proceed)
    }

    func testAnotherDeviceConflicts() {
        XCTAssertEqual(
            WriterClaimCheck.decide(
                found: claim(deviceId: "device-b"), deviceId: "device-a",
                namespaceId: "ns-1"),
            .conflict(claim(deviceId: "device-b")))
    }

    func testOurDeviceInAnotherNamespaceConflicts() {
        // The claim belongs to a namespace this run is not writing,
        // so it is not this run's claim.
        XCTAssertEqual(
            WriterClaimCheck.decide(
                found: claim(namespaceId: "ns-2"), deviceId: "device-a",
                namespaceId: "ns-1"),
            .conflict(claim(namespaceId: "ns-2")))
    }

    func testTheSplitIsTheDefaultResolution() {
        XCTAssertEqual(WriterClaimResolution.allCases.first, .split)
        XCTAssertEqual(WriterClaimResolution.takeOver.rawValue, "take-over")
    }

    func testTheClaimSurvivesAJSONRoundTrip() throws {
        let decoded = try WriterClaim.decode(json: try claim().jsonData())

        XCTAssertEqual(decoded, claim())
        XCTAssertEqual(decoded.version, WriterClaim.currentVersion)
    }

    func testTheDeviceRecordSurvivesAJSONRoundTrip() throws {
        let record = DeviceRecord(
            deviceId: "device-a", model: "iPhone17,1", name: "iPhone",
            lastWriteAt: claimedAt)
        let decoded = try DeviceRecord.decode(json: try record.jsonData())

        XCTAssertEqual(decoded, record)
    }
}

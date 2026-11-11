import Foundation
import XCTest

@testable import GameProbe

/// The seven error kinds of SPEC 8.4 and the run stop each one gives.
final class BackupProviderErrorTests: XCTestCase {

    func testAuthExpiredStopsTheRunForASignIn() {
        XCTAssertEqual(BackupProviderError.authExpired.runStop, .needsSignIn)
    }

    func testOutOfSpaceStopsTheRunAsFull() {
        // The engine runs the ladder of 5.14 first. A prune that frees
        // enough keeps the run.
        XCTAssertEqual(
            BackupProviderError.outOfSpace.runStop,
            .full(reason: QuotaCheck.prunedAndStillFullLine))
    }

    func testThrottledCarriesTheWait() {
        XCTAssertEqual(
            BackupProviderError.throttled(retryAfter: 12).runStop, .throttled(retryAfter: 12))
    }

    func testOfflineStopsTheRunAsOffline() {
        XCTAssertEqual(BackupProviderError.offline.runStop, .offline)
    }

    func testPermissionDeniedLeavesTheLineToTheRun() {
        XCTAssertNil(BackupProviderError.permissionDenied.runStop)
    }

    func testNotFoundAsksForANewBackup() {
        XCTAssertEqual(
            BackupProviderError.notFound.runStop,
            .rejected(
                message: "A backup file is missing from this location. Back up again to replace it."))
    }

    func testRejectedCarriesTheMessageWordForWord() {
        XCTAssertEqual(
            BackupProviderError.rejected(message: "bucket is read-only").runStop,
            .rejected(message: "bucket is read-only"))
    }

    func testAFileOverTheMaxFileSizeIsRejectedAndNotOutOfSpace() {
        let capabilities = TargetCapabilities(maxFileSize: 100)

        XCTAssertNil(capabilities.rejection(forFileOfSize: 100))
        guard case .rejected = capabilities.rejection(forFileOfSize: 101) else {
            return XCTFail("a file over the limit must be rejected")
        }
    }

    func testATargetWithNoStatedLimitRejectsNoFile() {
        let capabilities = TargetCapabilities(maxFileSize: nil)

        XCTAssertNil(capabilities.rejection(forFileOfSize: 1 << 40))
    }
}

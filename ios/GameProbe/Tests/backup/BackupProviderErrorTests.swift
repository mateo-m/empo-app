import Foundation
import XCTest

@testable import GameProbe

/// The seven error kinds of SPEC 8.4 and the one effect each has.
final class BackupProviderErrorTests: XCTestCase {

    func testAuthExpiredSendsTheTargetToNeedsSignInAndStopsTheRun() {
        let effect = BackupProviderError.authExpired.effect

        XCTAssertEqual(effect, .needsSignIn)
        XCTAssertTrue(effect.stopsTheRun)
    }

    func testOutOfSpaceRunsThePruneLadder() {
        let effect = BackupProviderError.outOfSpace.effect

        XCTAssertEqual(effect, .runPruneLadder)
        // The ladder of 5.14 decides. A prune that frees enough
        // keeps the run.
        XCTAssertFalse(effect.stopsTheRun)
    }

    func testThrottledCarriesTheWaitAndKeepsTheRun() {
        let effect = BackupProviderError.throttled(retryAfter: 12).effect

        XCTAssertEqual(effect, .waitAndKeepRun(seconds: 12))
        XCTAssertFalse(effect.stopsTheRun)
    }

    func testOfflineRetriesOnTheNextPass() {
        let effect = BackupProviderError.offline.effect

        XCTAssertEqual(effect, .retryOnNextPass)
        XCTAssertFalse(effect.stopsTheRun)
    }

    func testPermissionDeniedBlocksTheTarget() {
        let effect = BackupProviderError.permissionDenied.effect

        XCTAssertEqual(effect, .blocked)
        XCTAssertTrue(effect.stopsTheRun)
    }

    func testNotFoundDropsTheObjectFromTheCache() {
        let effect = BackupProviderError.notFound.effect

        XCTAssertEqual(effect, .dropFromCache)
        XCTAssertFalse(effect.stopsTheRun)
    }

    func testRejectedCarriesTheMessageWordForWordAndStopsTheRun() {
        let effect = BackupProviderError.rejected(message: "bucket is read-only").effect

        XCTAssertEqual(effect, .stopAndShow(message: "bucket is read-only"))
        XCTAssertTrue(effect.stopsTheRun)
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

import XCTest

@testable import Empo

@MainActor
final class BackupRunMonitorTests: XCTestCase {

    func testAnUploadOutsideThePlanDoesNotMoveTheRing() async {
        let monitor = BackupRunMonitor.shared
        monitor.runBegins()
        monitor.runCovers(names: [:], targetCount: 2)
        await monitor.runPlanned(streamKey: "settings", bytes: 1000)
        await monitor.runUploads(streamKey: "settings")
        await monitor.runConfirmed(streamKey: "settings", bytes: 1000)
        XCTAssertEqual(monitor.fraction, 0.5)

        // The snapshot file that closes the stream is not in the plan.
        monitor.transferSent(bytes: 4000)
        XCTAssertEqual(monitor.fraction, 0.5)
        monitor.runEnds(cancelled: false)
    }

    func testABlobInFlightMovesTheRingUpToItsOwnSize() async {
        let monitor = BackupRunMonitor.shared
        monitor.runBegins()
        monitor.runCovers(names: [:], targetCount: 1)
        await monitor.runPlanned(streamKey: "game", bytes: 1000)
        await monitor.runUploads(streamKey: "game")
        await monitor.runSendsBlob(bytes: 1000)
        monitor.transferSent(bytes: 400)
        XCTAssertEqual(monitor.fraction, 0.4)
        monitor.transferSent(bytes: 5000)
        XCTAssertEqual(monitor.fraction, 1)
        await monitor.runConfirmed(streamKey: "game", bytes: 1000)

        // A late report of the same upload lands after the confirm.
        monitor.transferSent(bytes: 1000)
        XCTAssertEqual(monitor.fraction, 1)
        monitor.runEnds(cancelled: false)
    }
}

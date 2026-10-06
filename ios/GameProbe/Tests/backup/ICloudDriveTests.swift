import Foundation
import XCTest

@testable import GameProbe

/// The iCloud Drive gate and error map of SPEC 9.1.
///
/// The provider needs a real ubiquity container, so these checks
/// cover the parts that do not.
final class ICloudDriveTests: XCTestCase {

    private let container = URL(fileURLWithPath: "/private/var/mobile/iCloud")

    private func target(provider: BackupProviderKind = .iCloudDrive) -> TargetDescriptor {
        TargetDescriptor(
            id: "target-1", provider: provider, label: "iCloud Drive",
            accountHint: "mateo@example.com", root: ICloudDrive.root)
    }

    // MARK: - The gate, per 9.1

    func testTheGateOpensOnlyWhenBothReadsAnswer() {
        let availability = ICloudDrive.availability(
            hasIdentityToken: true, containerURL: container)

        XCTAssertEqual(availability, .ready)
        XCTAssertTrue(ICloudDrive.showsInAddFlow(availability))
    }

    func testANilIdentityTokenClosesTheGate() {
        let availability = ICloudDrive.availability(
            hasIdentityToken: false, containerURL: container)

        XCTAssertEqual(availability, .notSignedIn)
        XCTAssertFalse(availability.isReady)
        XCTAssertFalse(ICloudDrive.showsInAddFlow(availability))
    }

    func testANilContainerURLClosesTheGate() {
        let availability = ICloudDrive.availability(
            hasIdentityToken: true, containerURL: nil)

        XCTAssertEqual(availability, .noContainer)
        XCTAssertFalse(ICloudDrive.showsInAddFlow(availability))
    }

    func testTwoNilReadsCloseTheGate() {
        // The token is read first, so it names the cause.
        let availability = ICloudDrive.availability(
            hasIdentityToken: false, containerURL: nil)

        XCTAssertEqual(availability, .notSignedIn)
        XCTAssertFalse(ICloudDrive.showsInAddFlow(availability))
    }

    func testTheContainerStringCarriesNoTeamId() {
        XCTAssertEqual(ICloudDrive.containerIdentifier, "iCloud.sh.mateo.empo")
        XCTAssertEqual(ICloudDrive.root, "Documents/Empo Backups")
    }

    // MARK: - The reprobe, per 9.1 and 13.5

    func testAProbeAnswersOnceForTheWholeLaunch() {
        var cache = ICloudProbeCache()
        XCTAssertNil(cache.value)

        cache.record(.ready)

        XCTAssertEqual(cache.value, .ready)
        XCTAssertEqual(cache.probeCount, 1)
    }

    func testTheIdentityChangeReprobesAndDisablesTheTargetWithoutDeletingIt() {
        let targets = [target(), target(provider: .dropbox)]
        var cache = ICloudProbeCache()
        cache.record(.ready)
        XCTAssertEqual(ICloudDrive.rowState(of: targets[0], availability: .ready), .usable)

        // The user signed out of iCloud.
        cache.identityDidChange()
        XCTAssertNil(cache.value)
        cache.record(.notSignedIn)

        guard let availability = cache.value else {
            return XCTFail("the reprobe left no answer")
        }
        XCTAssertEqual(cache.probeCount, 2)
        // The target keeps its row and reads the line of 9.1.
        XCTAssertEqual(
            ICloudDrive.rowState(of: targets[0], availability: availability),
            .cannotOpen(line: "iCloud is off or not signed in on this device"))
        // Nothing was deleted, and the target on another service is
        // untouched.
        XCTAssertEqual(targets.count, 2)
        XCTAssertNil(ICloudDrive.rowState(of: targets[1], availability: availability))
    }

    func testSigningBackInMakesTheTargetUsableAgainWithNoReAdd() {
        let descriptor = target()
        var cache = ICloudProbeCache()
        cache.record(.notSignedIn)
        cache.identityDidChange()
        cache.record(.ready)

        XCTAssertEqual(ICloudDrive.rowState(of: descriptor, availability: .ready), .usable)
        XCTAssertEqual(descriptor.id, "target-1")
    }

    // MARK: - The error map, per 8.4 and 9.1

    func testTheUploadingQuotaErrorMapsToOutOfSpace() {
        let error = ICloudDrive.error(
            domain: NSCocoaErrorDomain,
            code: ICloudDrive.CocoaCode.notUploadedDueToQuota,
            description: "there is not enough space in your iCloud account")

        XCTAssertEqual(error, .outOfSpace)
        // There is no space query on iCloud, per 9.7, so this is the
        // one door the ladder of 5.14 comes through.
        XCTAssertEqual(error.effect, .runPruneLadder)
    }

    func testAFullDiskMapsToOutOfSpace() {
        let error = ICloudDrive.error(
            domain: NSCocoaErrorDomain,
            code: ICloudDrive.CocoaCode.writeOutOfSpace,
            description: "the volume is full")

        XCTAssertEqual(error, .outOfSpace)
    }

    func testAnUnavailableServerMapsToOffline() {
        let error = ICloudDrive.error(
            domain: NSCocoaErrorDomain,
            code: ICloudDrive.CocoaCode.serverNotAvailable,
            description: "iCloud is not available")

        XCTAssertEqual(error, .offline)
        XCTAssertEqual(error.effect, .retryOnNextPass)
    }

    func testARefusedWriteMapsToPermissionDenied() {
        let error = ICloudDrive.error(
            domain: NSCocoaErrorDomain,
            code: ICloudDrive.CocoaCode.writeNoPermission,
            description: "you do not have permission")

        XCTAssertEqual(error, .permissionDenied)
        XCTAssertEqual(error.effect, .blocked)
    }

    func testAMissingItemMapsToNotFound() {
        for code in [
            ICloudDrive.CocoaCode.noSuchFile,
            ICloudDrive.CocoaCode.readNoSuchFile,
            ICloudDrive.CocoaCode.ubiquitousFileUnavailable,
        ] {
            let error = ICloudDrive.error(
                domain: NSCocoaErrorDomain, code: code, description: "no such file")

            XCTAssertEqual(error, .notFound, "code \(code)")
        }
    }

    func testALostRouteMapsToOffline() {
        let error = ICloudDrive.error(
            domain: NSURLErrorDomain, code: -1009,
            description: "the Internet connection appears to be offline")

        XCTAssertEqual(error, .offline)
    }

    func testAnUnknownFailureCarriesItsMessageWordForWord() {
        let error = ICloudDrive.error(
            domain: NSCocoaErrorDomain, code: 4_097,
            description: "the connection to service was interrupted")

        XCTAssertEqual(error, .rejected(message: "the connection to service was interrupted"))
        XCTAssertEqual(
            error.effect, .stopAndShow(message: "the connection to service was interrupted"))
    }

    // MARK: - The capability flags, per 8.3 and section 9

    func testTheFlagsReadAsTheTableOfSectionNineStatesThem() {
        let capabilities = ICloudDrive.capabilities

        XCTAssertFalse(capabilities.canQueryQuota)
        XCTAssertTrue(capabilities.reportsObjectAge)
        XCTAssertTrue(capabilities.supportsBackgroundTransfer)
        XCTAssertNil(capabilities.maxFileSize)
        XCTAssertFalse(capabilities.foldsCase)
    }

    func testNoFileSizeIsRejectedBecauseTheAccountQuotaSetsTheLimit() {
        XCTAssertNil(ICloudDrive.capabilities.rejection(forFileOfSize: 8 * 1024 * 1024 * 1024))
    }
}

import Foundation
import XCTest

@testable import GameProbe

/// The network, battery, heat, and running-game rules of SPEC 7.4,
/// 7.5, and 7.6.
final class ResourcePolicyTests: XCTestCase {

    // MARK: - A running game wins everything

    func testARunningGameStopsStaging() {
        XCTAssertEqual(
            ResourcePolicy.stagingGate(BackupConditions(isSessionLive: true)),
            .pause(.gameRunning))
    }

    func testTheManualButtonDoesNotBypassARunningGame() {
        XCTAssertEqual(
            ResourcePolicy.stagingGate(
                BackupConditions(isSessionLive: true, isManual: true)),
            .pause(.gameRunning))
    }

    func testAQuietDeviceWithNoSessionStages() {
        XCTAssertEqual(ResourcePolicy.stagingGate(BackupConditions()), .run)
    }

    // MARK: - Battery and heat

    func testLowPowerModeStopsStaging() {
        XCTAssertEqual(
            ResourcePolicy.stagingGate(BackupConditions(isLowPowerMode: true)),
            .pause(.lowPowerMode))
    }

    func testTheManualButtonBypassesLowPowerMode() {
        XCTAssertEqual(
            ResourcePolicy.stagingGate(
                BackupConditions(isLowPowerMode: true, isManual: true)),
            .run)
    }

    func testSeriousHeatPausesStagingAndFairDoesNot() {
        XCTAssertEqual(
            ResourcePolicy.stagingGate(BackupConditions(thermalState: .fair)), .run)
        XCTAssertEqual(
            ResourcePolicy.stagingGate(BackupConditions(thermalState: .serious)),
            .pause(.heat))
        XCTAssertEqual(
            ResourcePolicy.stagingGate(BackupConditions(thermalState: .critical)),
            .pause(.heat))
    }

    func testTheManualButtonDoesNotBypassHeat() {
        XCTAssertEqual(
            ResourcePolicy.stagingGate(
                BackupConditions(thermalState: .serious, isManual: true)),
            .pause(.heat))
    }

    func testStagingResumesAtFairOrLower() {
        XCTAssertTrue(ResourcePolicy.resumesStagingAfterHeat(.nominal))
        XCTAssertTrue(ResourcePolicy.resumesStagingAfterHeat(.fair))
        XCTAssertFalse(ResourcePolicy.resumesStagingAfterHeat(.serious))
        XCTAssertFalse(ResourcePolicy.resumesStagingAfterHeat(.critical))
    }

    func testUploadsInFlightKeepRunningThroughEveryCondition() {
        for session in [true, false] {
            for lowPower in [true, false] {
                for state in DeviceThermalState.allCases {
                    XCTAssertTrue(
                        ResourcePolicy.keepsUploadsInFlight(
                            BackupConditions(
                                isSessionLive: session, isLowPowerMode: lowPower,
                                thermalState: state)))
                }
            }
        }
    }

    // MARK: - Network

    func testWiFiOnlyIsTheDefault() {
        let policy = NetworkPolicy()
        XCTAssertFalse(policy.backsUpOverCellular)
        XCTAssertFalse(policy.allowsExpensiveNetworkAccess)
    }

    func testTheCellularSwitchOpensTheExpensiveAxisAlone() {
        let policy = NetworkPolicy(backsUpOverCellular: true)
        XCTAssertTrue(policy.allowsExpensiveNetworkAccess)
        XCTAssertFalse(policy.allowsConstrainedNetworkAccess)
    }

    func testLowDataModeIsAlwaysRespectedAndHasNoToggle() {
        for backsUpOverCellular in [true, false] {
            XCTAssertFalse(
                NetworkPolicy(backsUpOverCellular: backsUpOverCellular)
                    .allowsConstrainedNetworkAccess)
        }
    }

    func testAManualRunOnCellularAsksOnce() {
        let policy = NetworkPolicy()
        XCTAssertTrue(
            ResourcePolicy.asksAboutCellular(
                policy: policy, isManual: true, isOnCellular: true,
                alreadyAskedThisRun: false))
        XCTAssertFalse(
            ResourcePolicy.asksAboutCellular(
                policy: policy, isManual: true, isOnCellular: true,
                alreadyAskedThisRun: true))
    }

    func testAnAutomaticRunOnCellularNeverAsks() {
        XCTAssertFalse(
            ResourcePolicy.asksAboutCellular(
                policy: NetworkPolicy(), isManual: false, isOnCellular: true,
                alreadyAskedThisRun: false))
    }

    func testNothingAsksWhenTheCellularSwitchIsAlreadyOn() {
        XCTAssertFalse(
            ResourcePolicy.asksAboutCellular(
                policy: NetworkPolicy(backsUpOverCellular: true), isManual: true,
                isOnCellular: true, alreadyAskedThisRun: false))
    }

    func testACellularWaitBecomesTheStaleCause() {
        XCTAssertEqual(
            ResourcePolicy.blockedCause(policy: NetworkPolicy(), isOnCellular: true),
            .waitingForWiFi)
        XCTAssertNil(
            ResourcePolicy.blockedCause(policy: NetworkPolicy(), isOnCellular: false))
        XCTAssertNil(
            ResourcePolicy.blockedCause(
                policy: NetworkPolicy(backsUpOverCellular: true), isOnCellular: true))
    }
}

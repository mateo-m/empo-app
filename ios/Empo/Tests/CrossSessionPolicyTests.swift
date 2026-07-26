import XCTest

// No app-target import: EmpoTests compiles CrossSessionPolicy.swift
// directly (see project.yml), so the suite builds and runs without
// the app, its bridge, or a host application.

/// Truth-table tests for the cross-session decision core. These pin
/// the ordering contracts the adversarial review flagged as
/// load-bearing: hung short-circuits before the capability query,
/// first sessions are never gated, the memory gate is last and
/// skippable, and only recoverable session ends get library-return
/// framing.
final class CrossSessionPolicyTests: XCTestCase {

    // MARK: - Launch gate

    private func blocker(
        enabled: Bool = true,
        sessionsStarted: Int = 1,
        engineHung: Bool = false,
        includeMemoryGate: Bool = true,
        minimumBytes: Int = 500,
        capability: CrossSessionPolicy.Capability = .fresh,
        availableMemory: Int = 10_000,
        capabilityQueried: UnsafeMutablePointer<Bool>? = nil,
        memoryQueried: UnsafeMutablePointer<Bool>? = nil
    ) -> CrossSessionPolicy.Blocker? {
        CrossSessionPolicy.launchBlocker(
            enabled: enabled,
            sessionsStarted: sessionsStarted,
            engineHung: engineHung,
            includeMemoryGate: includeMemoryGate,
            minimumBytesForNextSession: minimumBytes,
            capability: {
                capabilityQueried?.pointee = true
                return capability
            },
            availableMemoryBytes: {
                memoryQueried?.pointee = true
                return availableMemory
            }
        )
    }

    func testFirstSessionIsNeverGated() {
        // Even with everything unfavorable, session 1 launches: its
        // footprint is the pre-cross-session status quo.
        var capabilityQueried = false
        var memoryQueried = false
        XCTAssertNil(
            blocker(
                sessionsStarted: 0,
                capability: .dirty,
                availableMemory: 0,
                capabilityQueried: &capabilityQueried,
                memoryQueried: &memoryQueried
            )
        )
        // And the gates must not even be evaluated.
        XCTAssertFalse(capabilityQueried)
        XCTAssertFalse(memoryQueried)
    }

    func testDisabledFlagBypassesEverything() {
        XCTAssertNil(
            blocker(enabled: false, capability: .dirty, availableMemory: 0)
        )
    }

    func testHungShortCircuitsBeforeCapability() {
        // A hung engine never terminates, so the capability query
        // would wrongly predict FRESH - and querying implies the
        // caller may proceed toward mkxp_setGamePath, which erases
        // the hung flag. The closure must not run.
        var capabilityQueried = false
        XCTAssertEqual(
            blocker(engineHung: true, capabilityQueried: &capabilityQueried),
            .engineHung
        )
        XCTAssertFalse(capabilityQueried)
    }

    func testDirtyCapabilityBlocks() {
        XCTAssertEqual(blocker(capability: .dirty), .dirtyRuby)
        XCTAssertEqual(blocker(capability: .unavailable), .dirtyRuby)
    }

    func testDirtyBlocksBeforeMemoryIsRead() {
        var memoryQueried = false
        _ = blocker(capability: .dirty, memoryQueried: &memoryQueried)
        XCTAssertFalse(memoryQueried)
    }

    func testMemoryGateBlocksBelowWatermark() {
        XCTAssertEqual(
            blocker(minimumBytes: 500, availableMemory: 499), .lowMemory
        )
        XCTAssertNil(blocker(minimumBytes: 500, availableMemory: 500))
    }

    func testQuitAndPlaySkipsMemoryGateOnly() {
        // includeMemoryGate: false must skip the memory reading
        // entirely (it would measure the quit game's still-resident
        // footprint) while keeping the capability gate.
        var memoryQueried = false
        XCTAssertNil(
            blocker(
                includeMemoryGate: false,
                availableMemory: 0,
                memoryQueried: &memoryQueried
            )
        )
        XCTAssertFalse(memoryQueried)
        XCTAssertEqual(
            blocker(includeMemoryGate: false, capability: .dirty),
            .dirtyRuby
        )
    }

    func testHappyPathLaunches() {
        XCTAssertNil(blocker())
    }

    // MARK: - Clean-exit routing

    func testCleanExitReturnsToLibraryOnlyWhenSafe() {
        // The one true path: enabled, no alert in flight, recoverable.
        XCTAssertTrue(
            CrossSessionPolicy.cleanExitReturnsToLibrary(
                enabled: true, errorAlertActive: false, recoverable: true
            )
        )
        // A presented alert (boot-gate parting message) must route
        // through the alert's OK instead: phase = nil under a
        // presented alert makes SwiftUI swallow the pop.
        XCTAssertFalse(
            CrossSessionPolicy.cleanExitReturnsToLibrary(
                enabled: true, errorAlertActive: true, recoverable: true
            )
        )
        // A failed quiesce (stuck instance) means the library is a
        // dead end; keep the honest alert.
        XCTAssertFalse(
            CrossSessionPolicy.cleanExitReturnsToLibrary(
                enabled: true, errorAlertActive: false, recoverable: false
            )
        )
        XCTAssertFalse(
            CrossSessionPolicy.cleanExitReturnsToLibrary(
                enabled: false, errorAlertActive: false, recoverable: true
            )
        )
    }

    func testFinishEndedSessionRequiresRecoverableAndActivePhase() {
        XCTAssertTrue(
            CrossSessionPolicy.canFinishEndedSession(
                enabled: true, phaseActive: true, recoverable: true
            )
        )
        // Mid-game errors: engine not recoverable-terminated, the
        // session must stay up.
        XCTAssertFalse(
            CrossSessionPolicy.canFinishEndedSession(
                enabled: true, phaseActive: true, recoverable: false
            )
        )
        XCTAssertFalse(
            CrossSessionPolicy.canFinishEndedSession(
                enabled: true, phaseActive: false, recoverable: true
            )
        )
        XCTAssertFalse(
            CrossSessionPolicy.canFinishEndedSession(
                enabled: false, phaseActive: true, recoverable: true
            )
        )
    }

    // MARK: - Alert framing

    func testHungAlwaysGetsRestartFraming() {
        XCTAssertEqual(
            CrossSessionPolicy.errorAlertTitle(
                engineHung: true, phaseActive: true,
                sessionEndedBehindAlert: true, cleanExit: true
            ),
            "Restart Empo"
        )
    }

    func testCrashWithStrandedInstanceKeepsRestartFraming() {
        // sessionEndedBehindAlert=false models the stranded case:
        // every next launch would be blocked, so no friendly title
        // and the force-close guidance stays.
        XCTAssertEqual(
            CrossSessionPolicy.errorAlertTitle(
                engineHung: false, phaseActive: true,
                sessionEndedBehindAlert: false, cleanExit: false
            ),
            "Restart Empo"
        )
        XCTAssertTrue(
            CrossSessionPolicy.appendsForceCloseGuidance(
                engineHung: false, phaseActive: true,
                sessionEndedBehindAlert: false
            )
        )
    }

    func testRecoverableCleanExitGetsGameEndedFraming() {
        XCTAssertEqual(
            CrossSessionPolicy.errorAlertTitle(
                engineHung: false, phaseActive: true,
                sessionEndedBehindAlert: true, cleanExit: true
            ),
            "Game ended"
        )
        XCTAssertFalse(
            CrossSessionPolicy.appendsForceCloseGuidance(
                engineHung: false, phaseActive: true,
                sessionEndedBehindAlert: true
            )
        )
    }

    func testRecoverablePreRubyFailureGetsNeutralFraming() {
        // Load error before Ruby ran: instance retired, library
        // usable - neutral title, no force-close text.
        XCTAssertEqual(
            CrossSessionPolicy.errorAlertTitle(
                engineHung: false, phaseActive: true,
                sessionEndedBehindAlert: true, cleanExit: false
            ),
            "Something went wrong"
        )
    }

    func testNoPhaseIsGenericError() {
        XCTAssertEqual(
            CrossSessionPolicy.errorAlertTitle(
                engineHung: false, phaseActive: false,
                sessionEndedBehindAlert: false, cleanExit: false
            ),
            "Something went wrong"
        )
        XCTAssertFalse(
            CrossSessionPolicy.appendsForceCloseGuidance(
                engineHung: false, phaseActive: false,
                sessionEndedBehindAlert: false
            )
        )
    }

    func testSessionEndedBehindAlertRequiresBoth() {
        XCTAssertTrue(
            CrossSessionPolicy.sessionEndedBehindAlert(
                enabled: true, recoverable: true
            )
        )
        XCTAssertFalse(
            CrossSessionPolicy.sessionEndedBehindAlert(
                enabled: true, recoverable: false
            )
        )
        XCTAssertFalse(
            CrossSessionPolicy.sessionEndedBehindAlert(
                enabled: false, recoverable: true
            )
        )
    }
}

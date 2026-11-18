// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Sentry
import XCTest

@testable import Empo

final class ErrorReportsBeforeSendTests: XCTestCase {

    /// The event that the Sentry SDK makes from a MetricKit crash
    /// report (SentryMXManager.captureEvent): one frame for each binary
    /// in the call stack, and one image for each binary that has a UUID.
    private func metricKitCrash(binaries: [String?], binariesWithoutUUID: [String?] = []) -> Event {
        let event = Event(level: .error)
        let mechanism = Mechanism(type: "MXCrashDiagnostic")
        mechanism.handled = false
        mechanism.synthetic = true
        let exception = Exception(value: "MachException Type:1 Code:1 Signal:11", type: "MXCrashDiagnostic")
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.debugMeta = binaries.map { binary in
            let image = DebugMeta()
            image.type = "macho"
            image.debugID = UUID().uuidString
            image.codeFile = binary
            return image
        }
        let thread = SentryThread(threadId: 0)
        thread.crashed = true
        thread.stacktrace = SentryStacktrace(
            frames: (binaries + binariesWithoutUUID).map { binary in
                let frame = Frame()
                frame.package = binary
                return frame
            },
            registers: [:])
        event.threads = [thread]
        return event
    }

    // EMPO-APP-3D: LiveContainer ran Bloons TD 5 HD, and Empo sent its
    // crash as an Empo crash.
    func testDropsTheCrashOfAnotherAppInLiveContainer() {
        let event = metricKitCrash(binaries: [
            "Bloons TD 5 HD", "UIKitCore", "FrontBoardServices", "libdispatch.dylib", "BoardServices",
            "CoreFoundation", "GraphicsServices", "LiveContainerShared", "dyld",
        ])
        XCTAssertNil(ErrorReports.beforeSend(event))
    }

    func testKeepsACrashOfEmpo() {
        let event = metricKitCrash(binaries: ["MkxpCore", "UIKitCore", "Empo", "dyld"])
        XCTAssertNotNil(ErrorReports.beforeSend(event))
    }

    func testKeepsACrashOfEmpoInLiveContainer() {
        let event = metricKitCrash(binaries: [
            "MkxpCore", "UIKitCore", "Empo", "LiveContainerShared", "dyld",
        ])
        XCTAssertNotNil(ErrorReports.beforeSend(event))
    }

    func testKeepsACrashOfTheGameProcess() {
        let event = metricKitCrash(binaries: ["MkxpCore", "GameProcess", "dyld"])
        XCTAssertNotNil(ErrorReports.beforeSend(event))
    }

    func testKeepsACrashWithAnUnnamedBinary() {
        let event = metricKitCrash(binaries: [nil, "UIKitCore", "LiveContainerShared", "dyld"])
        XCTAssertNotNil(ErrorReports.beforeSend(event))
    }

    func testKeepsACrashOfEmpoWithoutAUUID() {
        let event = metricKitCrash(
            binaries: ["UIKitCore", "LiveContainerShared", "dyld"], binariesWithoutUUID: ["Empo"])
        XCTAssertNotNil(ErrorReports.beforeSend(event))
    }

    func testKeepsACrashWithAnUnnamedBinaryWithoutAUUID() {
        let event = metricKitCrash(
            binaries: ["UIKitCore", "LiveContainerShared", "dyld"], binariesWithoutUUID: [nil])
        XCTAssertNotNil(ErrorReports.beforeSend(event))
    }

    func testKeepsACrashWithNoBinaries() {
        XCTAssertNotNil(ErrorReports.beforeSend(metricKitCrash(binaries: [])))
    }

    func testKeepsAGameError() {
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "Script 'Main' line 1: NameError occurred.")
        XCTAssertNotNil(ErrorReports.beforeSend(event))
    }
}

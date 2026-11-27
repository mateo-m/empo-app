// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

private final class StderrBytes: @unchecked Sendable {
    var value = Data()
}

@MainActor
final class MvmzLogTests: XCTestCase {
    private var logURL: URL!

    override func setUpWithError() throws {
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MvmzLogTests-\(UUID().uuidString).log")
        try Data().write(to: logURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: logURL)
    }

    // EMPO-APP-78: a full stderr must not stop the main thread.
    func testCoreLogLinesDoNotWaitForAStderrThatNobodyReads() throws {
        guard let binary = MvmzCore().binaryURL else {
            throw XCTSkip("this build has no MvmzCore")
        }
        let core = try XCTUnwrap(dlopen(binary.path, RTLD_NOW | RTLD_LOCAL), String(cString: dlerror()))
        typealias SetDebugLogPath = @convention(c) (UnsafePointer<CChar>?) -> Void
        let setDebugLogPath = unsafeBitCast(
            try XCTUnwrap(dlsym(core, "gamecore_setDebugLogPath")), to: SetDebugLogPath.self)

        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let savedStderr = dup(STDERR_FILENO)
        guard savedStderr >= 0, dup2(ends[1], STDERR_FILENO) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close(ends[1])

        let readEnd = ends[0]
        let drained = expectation(description: "stderr drained")
        let bytesOnStderr = StderrBytes()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(readEnd, &buffer, buffer.count)
                if count <= 0 {
                    break
                }
                bytesOnStderr.value.append(buffer, count: count)
            }
            drained.fulfill()
        }

        let lines = 2000
        let start = Date()
        for _ in 0..<lines {
            setDebugLogPath(logURL.path)
        }
        let elapsed = Date().timeIntervalSince(start)
        setDebugLogPath(nil)

        dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)
        wait(for: [drained], timeout: 10)
        close(readEnd)

        XCTAssertLessThan(elapsed, 1, "the main thread waited \(elapsed) s for stderr")
        // Other parts of the app can write to stderr while the test runs.
        XCTAssertNil(bytesOnStderr.value.range(of: Data("log is attached".utf8)))
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "log is attached\n").count - 1, lines)
    }
}

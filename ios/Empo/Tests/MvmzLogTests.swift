// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

private final class ByteCount: @unchecked Sendable {
    var value = 0
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

    // Under LiveContainer, stderr can be a pipe that nothing reads. A write to
    // it waits when the pipe is full, and iOS ended Empo while an MV game
    // logged on the main thread.
    func testCoreLogLinesDoNotWaitForAStderrThatNobodyReads() throws {
        let binary = try XCTUnwrap(Bundle.main.privateFrameworksURL)
            .appendingPathComponent("MvmzCore.framework/MvmzCore")
        let core = try XCTUnwrap(dlopen(binary.path, RTLD_NOW | RTLD_LOCAL), String(cString: dlerror()))
        typealias SetDebugLogPath = @convention(c) (UnsafePointer<CChar>?) -> Void
        let setDebugLogPath = unsafeBitCast(
            try XCTUnwrap(dlsym(core, "gamecore_setDebugLogPath")), to: SetDebugLogPath.self)

        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        let savedStderr = dup(STDERR_FILENO)
        dup2(ends[1], STDERR_FILENO)
        close(ends[1])

        let readEnd = ends[0]
        let drained = expectation(description: "stderr drained")
        let bytesOnStderr = ByteCount()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(readEnd, &buffer, buffer.count)
                if count <= 0 {
                    break
                }
                bytesOnStderr.value += count
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
        XCTAssertEqual(bytesOnStderr.value, 0)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "log is attached\n").count - 1, lines)
    }
}

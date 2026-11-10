// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

/// A read that answers only when the test says so.
@MainActor
final class HeldAnswer<Value> {
    private var waiting: [CheckedContinuation<Value, Never>] = []

    func value() async -> Value {
        await withCheckedContinuation { waiting.append($0) }
    }

    func answer(_ value: Value) {
        waiting.forEach { $0.resume(returning: value) }
        waiting = []
    }
}

@MainActor
final class BackupStopTests: XCTestCase {

    func testAPausedPassStopsWhileThePlusReadsDoNotAnswer() async {
        let reads = HeldAnswer<Void>()
        let pass = BackupPass(readThePlus: { await reads.value() })
        let stopped = expectation(description: "the pass stops")
        let run = Task {
            let result = await pass.runBackup(
                scope: .dirtyGames, trigger: .sessionEndOrBackground, progress: nil)
            stopped.fulfill()
            return result
        }
        run.cancel()

        await fulfillment(of: [stopped], timeout: 5)
        reads.answer(())

        let result = await run.value
        XCTAssertFalse(result.didFinish)
        XCTAssertTrue(result.targets.isEmpty)
    }

    func testACancelledSizeCountStops() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("size-count-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 1000).write(to: folder.appendingPathComponent("Save1.rvdata2"))
        let fullSize = await GameMetadata.diskSize(for: folder)
        XCTAssertEqual(fullSize, 1000)

        let count = Task { await GameMetadata.diskSize(for: folder) }
        count.cancel()

        let cancelledSize = await count.value
        XCTAssertEqual(cancelledSize, 0)
    }
}

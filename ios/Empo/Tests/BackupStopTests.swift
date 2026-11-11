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
        let started = expectation(description: "the Plus reads start")
        let pass = BackupPass(readThePlus: {
            started.fulfill()
            await reads.value()
        })
        let stopped = expectation(description: "the pass stops")
        let run = Task {
            let result = await pass.runBackup(
                scope: .dirtyGames, trigger: .sessionEndOrBackground, progress: nil)
            stopped.fulfill()
            return result
        }
        await fulfillment(of: [started], timeout: 5)
        run.cancel()

        await fulfillment(of: [stopped], timeout: 5)
        reads.answer(())

        let result = await run.value
        XCTAssertFalse(result.didFinish)
        XCTAssertTrue(result.targets.isEmpty)
    }

    func testAPausedPassStopsWhileALocationDoesNotOpen() async throws {
        let files = [
            BackupRoot.layout.targetsFile,
            BackupRoot.layout.root.appendingPathComponent("ledger-rebuild.json"),
        ]
        let saved = files.map { try? Data(contentsOf: $0) }
        defer {
            for (file, data) in zip(files, saved) {
                if let data {
                    try? data.write(to: file, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        try BackupTargets.add(
            TargetDescriptor(
                id: "held-open-\(UUID().uuidString)", provider: .iCloudDrive, label: "Test",
                root: "Empo"))
        let opening = HeldAnswer<(any BackupProvider)?>()
        let started = expectation(description: "a location starts to open")
        started.assertForOverFulfill = false
        let pass = BackupPass(
            readThePlus: {},
            openTheProvider: { _ in
                started.fulfill()
                return await opening.value()
            })
        let stopped = expectation(description: "the pass stops")
        let run = Task {
            let result = await pass.runBackup(
                scope: .dirtyGames, trigger: .sessionEndOrBackground, progress: nil)
            stopped.fulfill()
            return result
        }
        await fulfillment(of: [started], timeout: 5)
        run.cancel()

        await fulfillment(of: [stopped], timeout: 5)
        opening.answer(nil)

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

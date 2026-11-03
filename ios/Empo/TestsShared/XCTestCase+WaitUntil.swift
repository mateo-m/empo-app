// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

extension XCTestCase {
    /// GameController queues element handlers on its handler queue, and
    /// SDL gives events only when a timer pumps them. Neither offers a
    /// completion signal, so the tests poll the observable result.
    @MainActor
    func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition did not hold within 2 s", file: file, line: line)
    }

    /// Enough main-queue turns for queued handlers to land, for a test
    /// that expects no result.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }
}

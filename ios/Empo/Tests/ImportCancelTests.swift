// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

@MainActor
final class ImportCancelTests: XCTestCase {
    private let library = GameLibrary.shared
    private let id = "ImportCancelTests-\(UUID().uuidString)"

    override func tearDown() {
        library.endInFlightImport(id)
        super.tearDown()
    }

    func testStopOfAnImportThatEndedDoesNothing() {
        library.cancelImport(id)

        XCTAssertFalse(library.isImportCancelled(id))
        library.inFlightImports.withLock { _ = $0.insert(id) }
        XCTAssertFalse(library.isImportCancelled(id))
    }

    func testStopOfAnImportInProgressCancelsItUntilItEnds() {
        library.inFlightImports.withLock { _ = $0.insert(id) }

        library.cancelImport(id)
        XCTAssertTrue(library.isImportCancelled(id))

        library.endInFlightImport(id)
        XCTAssertFalse(library.isImportCancelled(id))
    }
}

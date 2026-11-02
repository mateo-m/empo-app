// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import GameProbe

final class BindingMapCodableTests: XCTestCase {
    func testRoundTripKeepsUnboundSources() throws {
        let map = BindingMap(entries: [
            .element("a"): .key("Enter"),
            .element("b"): .unbound,
            .element("y"): .action("$pauseMenu"),
        ])

        let data = try JSONEncoder().encode([map])
        XCTAssertEqual(try JSONDecoder().decode([BindingMap].self, from: data), [map])
    }
}

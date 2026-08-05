import XCTest

@testable import GameProbe

final class EmpoActionTests: XCTestCase {

    func testIDsAreUniqueAndPrefixed() {
        let ids = EmpoActionCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertTrue(id.hasPrefix("$"), id)
        }
    }

    func testMetadataIsNonEmpty() {
        // The docs and pickers render these strings directly.
        for action in EmpoActionCatalog.all {
            XCTAssertFalse(action.displayName.isEmpty, action.id)
            XCTAssertFalse(action.blurb.isEmpty, action.id)
            XCTAssertFalse(action.symbolName.isEmpty, action.id)
        }
    }

    func testTouchIDsExcludeControllerOnlyActions() {
        XCTAssertFalse(EmpoActionCatalog.touchIDs.contains(EmpoActionCatalog.toggleTouchControls))
        XCTAssertEqual(
            EmpoActionCatalog.touchIDs,
            Set([
                EmpoActionCatalog.fastForwardHold,
                EmpoActionCatalog.fastForwardToggle,
                EmpoActionCatalog.pauseMenu,
                EmpoActionCatalog.toggleCheats,
            ])
        )
    }

    func testMigrationRewritesRenamedAction() {
        let map = ControllerMap(entries: [
            "back": .action("$toggleOverlay"),
            "start": .action("$pauseMenu"),
            "y": .key("F5"),
            "x": .unbound,
        ])
        let first = EmpoActionCatalog.migrated(map)
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.map.entries["back"], .action("$toggleTouchControls"))
        XCTAssertEqual(first.map.entries["start"], .action("$pauseMenu"))
        XCTAssertEqual(first.map.entries["y"], .key("F5"))
        XCTAssertEqual(first.map.entries["x"], .unbound)

        let second = EmpoActionCatalog.migrated(first.map)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.map, first.map)
    }

    func testMigrationLeavesUnknownActionsAlone() {
        let map = ControllerMap(entries: ["start": .action("$notAnAction")])
        let result = EmpoActionCatalog.migrated(map)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.map, map)
    }

    func testRenamedIDsAreConsistentWithCatalog() {
        // Every rename target must exist; every old id must be gone
        // from the catalog, or the "no alias" rule is broken.
        for (old, new) in EmpoActionCatalog.renamedIDs {
            XCTAssertTrue(EmpoActionCatalog.allIDs.contains(new), new)
            XCTAssertFalse(EmpoActionCatalog.allIDs.contains(old), old)
        }
    }
}

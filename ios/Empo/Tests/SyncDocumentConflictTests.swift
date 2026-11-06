// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Automerge
import GameProbe
import XCTest

@testable import Empo

final class SyncDocumentConflictTests: XCTestCase {

    private func layout(_ value: String) -> SyncDocumentModel {
        var model = SyncDocumentModel()
        model.layoutProfiles = ["p1": SyncProfile(name: "Pad", controls: ["a": .string(value)])]
        return model
    }

    func testThreeDevicesThatEditOneControlLeaveTwoLosingVersions() throws {
        let base = SyncDocument.make(actorId: UUID().uuidString)
        try SyncDocument.write(layout("start"), to: base)
        let bytes = base.save()

        let devices = try ["left", "right", "up"].map { value -> Document in
            let device = try SyncDocument.open(bytes, actorId: UUID().uuidString)
            try SyncDocument.write(layout(value), to: device)
            return device
        }
        let merged = devices[0]
        try merged.merge(other: devices[1])
        try merged.merge(other: devices[2])

        let winner = try XCTUnwrap(
            SyncDocument.model(of: merged).layoutProfiles["p1"]?.controls["a"])
        let losing = try SyncDocument.losingControls(of: merged, profileId: "p1")

        XCTAssertEqual(losing.count, 2)
        let values = losing.compactMap { $0["a"] } + [winner]
        for value in ["left", "right", "up"] {
            XCTAssertTrue(values.contains(.string(value)), "\(value) was lost")
        }

        try SyncDocument.resolveControls(of: merged, profileId: "p1", keys: ["a"])
        XCTAssertTrue(try SyncDocument.losingControls(of: merged, profileId: "p1").isEmpty)
    }

    func testTwoDocumentsWithNoSharedHistoryKeepOnlyOneSidesLayouts() throws {
        let group = SyncDocument.make(actorId: UUID().uuidString)
        try SyncDocument.write(layout("group"), to: group)
        var mine = SyncDocumentModel()
        mine.layoutProfiles = ["p2": SyncProfile(name: "Mine", controls: ["b": .string("x")])]
        let alone = SyncDocument.make(actorId: UUID().uuidString)
        try SyncDocument.write(mine, to: alone)

        try group.merge(other: alone)

        let profiles = try SyncDocument.model(of: group).layoutProfiles
        XCTAssertEqual(profiles.count, 1)
    }

    func testADeviceThatLostItsDocumentMergesOnlyWithANewActor() throws {
        let actorId = UUID().uuidString
        let lost = SyncDocument.make(actorId: actorId)
        try SyncDocument.write(layout("before"), to: lost)
        let other = try SyncDocument.open(lost.save(), actorId: UUID().uuidString)

        let sameActor = SyncDocument.make(actorId: actorId)
        try SyncDocument.write(layout("after"), to: sameActor)
        XCTAssertThrowsError(try other.merge(other: sameActor))

        let newActor = SyncDocument.make(actorId: UUID().uuidString)
        try SyncDocument.write(layout("after"), to: newActor)
        XCTAssertNoThrow(try other.merge(other: newActor))
    }
}

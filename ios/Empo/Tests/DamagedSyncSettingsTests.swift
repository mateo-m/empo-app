// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

/// These tests write the real files of the test host, so each one puts the files back at the end.
@MainActor
final class DamagedSyncSettingsTests: XCTestCase {

    private let damaged = Data("{\"groupId\":".utf8)
    private let key = PreferenceKeys.hintDismissedPrefix + "damagedSyncSettingsTest"
    private var saved: [URL: Data?] = [:]

    private var layout: BackupRootLayout { BackupRoot.layout }
    private var syncFile: URL { layout.applicationSupport.appendingPathComponent(SyncState.fileName) }

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(BackupRoot.prepare())
        let kept = [
            syncFile, layout.targetsFile, layout.preferenceRollbackFile,
            layout.applicationSupport.appendingPathComponent(WriterConflicts.fileName),
            PreferenceRestore.restoredFile,
            layout.root.appendingPathComponent("ledger-rebuild.json"),
        ]
        for url in kept {
            saved[url] = .some(try? Data(contentsOf: url))
        }
        try damaged.write(to: syncFile)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: key)
        for (url, data) in saved {
            if let data {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try await super.tearDown()
    }

    func testALocationAddsAndRemovesAndTheSyncSettingsStayAsTheyWere() async throws {
        let target = TargetDescriptor(
            id: "damaged-sync-\(UUID().uuidString)", provider: .webdav, label: "Test",
            root: "Empo")

        try BackupTargets.add(target)
        XCTAssertTrue(BackupTargets.load().contains { $0.id == target.id })

        let line = await BackupsScreenModel().remove(targetId: target.id, deleteBackups: false)

        XCTAssertNil(line)
        XCTAssertFalse(BackupTargets.load().contains { $0.id == target.id })
        XCTAssertEqual(try Data(contentsOf: syncFile), damaged)
    }

    func testALocationRemovalAnswersWhileTheICloudCheckDoesNotAnswer() async throws {
        let target = TargetDescriptor(
            id: "unanswered-icloud-\(UUID().uuidString)", provider: .webdav, label: "Test",
            root: "Empo")
        try BackupTargets.add(target)
        let check = HeldAnswer<ICloudAvailability>()
        let model = BackupsScreenModel(iCloudAvailability: { await check.value() })
        let removed = expectation(description: "the removal answers")
        let removal = Task {
            let line = await model.remove(targetId: target.id, deleteBackups: false)
            removed.fulfill()
            return line
        }

        await fulfillment(of: [removed], timeout: 5)
        check.answer(.signedOut)

        let line = await removal.value
        XCTAssertNil(line)
        XCTAssertFalse(BackupTargets.load().contains { $0.id == target.id })
        XCTAssertEqual(model.items?.contains { $0.id == target.id }, false)
    }

    func testALocationRemovalStopsWhenTheSyncSettingsDoNotOpen() async throws {
        let target = TargetDescriptor(
            id: "unopened-sync-\(UUID().uuidString)", provider: .webdav, label: "Test",
            root: "Empo")
        try BackupTargets.add(target)
        try FileManager.default.removeItem(at: syncFile)
        try FileManager.default.createDirectory(at: syncFile, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: syncFile) }

        let line = await BackupsScreenModel().remove(targetId: target.id, deleteBackups: false)

        XCTAssertNotNil(line)
        XCTAssertTrue(BackupTargets.load().contains { $0.id == target.id })
    }

    func testARemovedLocationTakesItsAdoptBannerAway() async throws {
        let target = TargetDescriptor(
            id: "adopt-banner-\(UUID().uuidString)", provider: .webdav, label: "Test", root: "Empo")
        try BackupTargets.add(target)
        let model = BackupsScreenModel(iCloudAvailability: { .signedOut })
        await model.refresh()
        model.showTheAdoptBanners(
            [
                BackupNamespaceRow(
                    namespaceId: "earlier-\(UUID().uuidString)", deviceName: "Test", snapshotCount: 1,
                    gameCount: 1, totalBytes: nil, isEarlierSpace: true)
            ], of: target.id)
        XCTAssertEqual(model.adoptBanners.map(\.targetId), [target.id])

        let line = await model.remove(targetId: target.id, deleteBackups: false)

        XCTAssertNil(line)
        XCTAssertTrue(model.adoptBanners.isEmpty)
    }

    func testSetUpSyncAgainMovesTheDamagedFileAsideAndStartsTheJoin() async throws {
        let folder = layout.applicationSupport
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        try BackupTargets.add(
            TargetDescriptor(
                id: "set-up-again-\(UUID().uuidString)", provider: .webdav, label: "Test",
                root: "Empo"))
        XCTAssertTrue(SyncStore.settingsAreDamaged())

        let ask = try await SyncJoin.setUpAgain()

        let asides = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
            .subtracting(before).filter { $0.hasPrefix("sync.damaged-") }
        defer {
            for name in asides {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        XCTAssertEqual(asides.count, 1)
        XCTAssertEqual(
            try asides.first.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, damaged)
        XCTAssertFalse(SyncStore.settingsAreDamaged())
        XCTAssertFalse(SyncPass.shared.settingsAreDamaged)
        XCTAssertNotNil(try SyncStore.state().groupId)
        XCTAssertEqual(ask, SyncJoinAsk.none)
    }

    func testTheRunSettingsKeepTheGroupWhenTheSyncSettingsDoNotRead() throws {
        let folder = layout.applicationSupport
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        try damaged.write(to: folder.appendingPathComponent(WriterConflicts.fileName))

        let settings = try BackupPass.shared.runSettings(targetId: "test", label: "Test")

        let asides = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
            .subtracting(before).filter { $0.hasPrefix("writer-conflicts.damaged-") }
        defer {
            for name in asides {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        XCTAssertNil(settings.writerAnswer)
        XCTAssertEqual(settings.syncGroup, .keepRecorded)
        XCTAssertEqual(asides.count, 1)
    }

    func testARestoreThatDeletesNothingApplies() throws {
        UserDefaults.standard.set(true, forKey: key)
        var snapshot = DevicePreferences.currentDefaults()
        snapshot[key] = .bool(false)
        try writeTheRestoredFile(snapshot)

        XCTAssertTrue(PreferenceRestore.applyTheRestoredFile())

        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: syncFile), damaged)
    }

    func testAnUndoThatDeletesNothingApplies() throws {
        UserDefaults.standard.set(true, forKey: key)
        var values = DevicePreferences.currentDefaults()
        values[key] = .bool(false)
        try PreferenceRollbackUndo(savedAt: Date(), values: values)
            .write(applicationSupport: layout.applicationSupport)

        XCTAssertTrue(PreferenceRestore.undo())

        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: syncFile), damaged)
    }

    func testARestoreThatDeletesASettingFailsAndKeepsIt() throws {
        UserDefaults.standard.set(true, forKey: key)
        var snapshot = DevicePreferences.currentDefaults()
        snapshot[key] = nil
        try writeTheRestoredFile(snapshot)

        XCTAssertFalse(PreferenceRestore.applyTheRestoredFile())

        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, true)
        XCTAssertFalse(PreferenceRestore.hasUndo())
        XCTAssertEqual(try Data(contentsOf: syncFile), damaged)
    }

    func testAnUndoThatDeletesASettingFailsAndKeepsIt() throws {
        UserDefaults.standard.set(true, forKey: key)
        var values = DevicePreferences.currentDefaults()
        values[key] = nil
        try PreferenceRollbackUndo(savedAt: Date(), values: values)
            .write(applicationSupport: layout.applicationSupport)

        XCTAssertFalse(PreferenceRestore.undo())

        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: syncFile), damaged)
    }

    private func writeTheRestoredFile(_ values: [String: JSONValue]) throws {
        try PreferenceExport.document(of: values, at: Date())
            .write(to: PreferenceRestore.restoredFile, options: .atomic)
    }
}

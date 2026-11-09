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
        ]
        for url in kept {
            saved[url] = try? Data(contentsOf: url)
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

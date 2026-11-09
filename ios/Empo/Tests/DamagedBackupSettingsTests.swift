// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

/// These tests write the real files of the test host, so each one puts the files back at the end.
@MainActor
final class DamagedBackupSettingsTests: XCTestCase {

    private let damaged = Data("{\"mode\":".utf8)
    private var saved: [URL: Data?] = [:]
    private var container: GameContainer!

    private var layout: BackupRootLayout { BackupRoot.layout }
    private var conflictsFile: URL {
        layout.applicationSupport.appendingPathComponent(WriterConflicts.fileName)
    }
    private var conflictsAside: URL {
        layout.applicationSupport.appendingPathComponent("writer-conflicts.damaged.json")
    }
    private var intentFile: URL {
        container.empoStateURL.appendingPathComponent(GameBackupIntent.fileName)
    }

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(BackupRoot.prepare())
        let kept = [
            conflictsFile, conflictsAside, layout.targetsFile,
            layout.applicationSupport.appendingPathComponent(SyncState.fileName),
        ]
        for url in kept {
            saved[url] = try? Data(contentsOf: url)
        }
        container = GameContainer(folderName: "damaged-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container.empoStateURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for (url, data) in saved {
            if let data {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? FileManager.default.removeItem(at: container.url)
        try await super.tearDown()
    }

    func testAStoppedRunOverDamagedWriterAnswersLeavesAQuestionOnTheBackupsScreen() async throws {
        let target = TargetDescriptor(
            id: "damaged-answers-\(UUID().uuidString)", provider: .webdav, label: "Test",
            root: "Empo")
        try BackupTargets.add(target)
        try damaged.write(to: conflictsFile)

        var conflicts = try BackupRoot.writerConflicts()
        let claim = WriterClaim(
            namespaceId: "other", deviceId: "other-device", deviceName: "Other iPad",
            claimedAt: Date())
        conflicts.runEnded(targetId: target.id, stop: .writerConflict(claim), didSplit: false)
        try conflicts.write(applicationSupport: layout.applicationSupport)

        let model = BackupsScreenModel()
        await model.refresh()

        XCTAssertEqual(model.writerQuestions.map(\.deviceName), ["Other iPad"])
        XCTAssertEqual(try Data(contentsOf: conflictsAside), damaged)
    }

    func testAModeChoiceOverADamagedSettingsFileIsSavedAndTheOldFileStays() async throws {
        try damaged.write(to: intentFile)

        XCTAssertTrue(try GameBackupSets.setMode(.full, for: container))

        XCTAssertEqual(try GameBackupIntent.load(from: container.empoStateURL).mode, .full)
        let resolution = try await GameBackupSets.resolveMode(for: container, targets: [])
        XCTAssertEqual(resolution, .mode(.full))
        XCTAssertEqual(
            try Data(
                contentsOf: container.empoStateURL.appendingPathComponent("backup.damaged.json")),
            damaged)
    }

    func testADamagedSettingsFileStopsTheModeAndTheSetReads() async throws {
        try damaged.write(to: intentFile)

        do {
            _ = try await GameBackupSets.resolveMode(for: container, targets: [])
            XCTFail("The mode read must not take a damaged file as no answer")
        } catch {}
        do {
            _ = try await GameBackupSets.request(for: container, mode: .slim)
            XCTFail("The set read must not take a damaged file as no marks")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: intentFile), damaged)
    }
}

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
    private var namesBefore: [URL: Set<String>] = [:]
    private var container: GameContainer!

    private var layout: BackupRootLayout { BackupRoot.layout }
    private var conflictsFile: URL {
        layout.applicationSupport.appendingPathComponent(WriterConflicts.fileName)
    }
    private var intentFile: URL {
        container.empoStateURL.appendingPathComponent(GameBackupIntent.fileName)
    }

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(BackupRoot.prepare())
        let kept = [
            conflictsFile, layout.targetsFile,
            layout.applicationSupport.appendingPathComponent(SyncState.fileName),
            layout.root.appendingPathComponent("ledger-rebuild.json"),
            layout.root.appendingPathComponent("namespace-clear.json"),
        ]
        for url in kept {
            saved[url] = try? Data(contentsOf: url)
        }
        for directory in [layout.applicationSupport, layout.root] {
            namesBefore[directory] = names(in: directory)
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
        for (directory, before) in namesBefore {
            for name in names(in: directory).subtracting(before) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        try? FileManager.default.removeItem(at: container.url)
        try await super.tearDown()
    }

    func testAStoppedRunOverDamagedWriterAnswersLeavesAQuestionOnTheBackupsScreen() async throws {
        let target = try addATarget()
        try damaged.write(to: conflictsFile)

        try BackupPass.recordTheWriterAnswers(
            targetId: target.id, answerAtStart: nil,
            result: runResult(stop: .writerConflict(otherDevice)))

        let model = BackupsScreenModel()
        await model.refresh()

        XCTAssertEqual(model.writerQuestions.map(\.deviceName), ["Other iPad"])
        XCTAssertEqual(try damagedCopies(of: conflictsFile), [damaged])
    }

    func testAnAnswerGivenDuringARunStaysAfterTheRun() throws {
        let target = try addATarget()
        var conflicts = WriterConflicts()
        conflicts.runEnded(targetId: target.id, stop: .writerConflict(otherDevice), didSplit: false)
        try conflicts.write(applicationSupport: layout.applicationSupport)

        var answered = try BackupRoot.writerConflicts()
        answered.answer(targetId: target.id, resolution: .takeOver)
        try answered.write(applicationSupport: layout.applicationSupport)
        try BackupPass.recordTheWriterAnswers(
            targetId: target.id, answerAtStart: nil,
            result: runResult(stop: .writerConflict(otherDevice)))

        XCTAssertEqual(try BackupRoot.writerConflicts().answer(for: target.id), .takeOver)
    }

    func testTheBackupSheetAsksForTheModeAgainOverADamagedSettingsFile() async throws {
        try damaged.write(to: intentFile)
        let model = BackupSheetModel(container: container, gameName: "Test")

        await model.load()
        XCTAssertTrue(model.settingsUnread)
        XCTAssertNil(model.editor)

        await model.setMode(.slim)
        XCTAssertFalse(model.settingsUnread)
        XCTAssertNotNil(model.editor)
        XCTAssertEqual(model.mode, .slim)
    }

    func testAnExportOfABigGameWithDamagedSettingsStopsAndNamesTheGame() async throws {
        let target = TargetDescriptor(
            id: "damaged-settings-\(UUID().uuidString)", provider: .webdav, label: "Test",
            root: "Empo", sizeThresholdBytes: 0)
        try BackupTargets.add(target)
        try damaged.write(to: intentFile)

        do {
            _ = try await PackageExport.plan(game: container)
            XCTFail("A slim export must not read a damaged file as no marks")
        } catch let unread as PackageExport.SettingsUnread {
            XCTAssertEqual(unread.gameName, BackupGameNames.name(of: container))
        }
    }

    func testADamagedNamespaceListRebuildsTheSnapshotListOfEveryTarget() throws {
        let target = try addATarget()
        let clearList = BackupTargetWaitList(fileName: "namespace-clear.json")
        try damaged.write(to: clearList.fileURL)
        let store = try BackupRoot.openStateStore()
        defer { store.close() }

        try BackupNamespaceMove.clearIfWaiting(targetId: target.id, store: store)

        XCTAssertTrue(
            try BackupTargetWaitList(fileName: "ledger-rebuild.json").ids().contains(target.id))
    }

    func testAModeChoiceOverADamagedSettingsFileIsSavedAndTheOldFileStays() async throws {
        try damaged.write(to: intentFile)

        XCTAssertTrue(try GameBackupSets.setMode(.slim, for: container))

        XCTAssertEqual(try GameBackupIntent.load(from: container.empoStateURL).mode, .slim)
        let resolution = await GameBackupSets.resolveMode(for: container, targets: [])
        XCTAssertEqual(resolution, .mode(.slim))
        XCTAssertEqual(try damagedCopies(of: intentFile), [damaged])
    }

    func testADamagedSettingsFileAsksTheModeAgainAndStopsOnlyASlimSet() async throws {
        try damaged.write(to: intentFile)
        let lowLimit = BackupTargetThreshold(targetId: "low", displayName: "Low", overrideBytes: 0)

        let small = await GameBackupSets.resolveMode(for: container, targets: [])
        let big = await GameBackupSets.resolveMode(for: container, targets: [lowLimit])
        let full = try await GameBackupSets.request(for: container, mode: .full)

        XCTAssertEqual(small, .mode(.full))
        guard case .ask = big else { return XCTFail("A big game must wait for the question, not \(big)") }
        XCTAssertEqual(full.mode, .full)
        do {
            _ = try await GameBackupSets.request(for: container, mode: .slim)
            XCTFail("A slim set must not read a damaged file as no marks")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: intentFile), damaged)
    }

    func testADamagedWaitListMakesEveryTargetWait() throws {
        let target = try addATarget()
        let list = BackupTargetWaitList(fileName: "damaged-wait-\(UUID().uuidString).json")
        try damaged.write(to: list.fileURL)

        XCTAssertTrue(try list.ids().contains(target.id))
        try list.remove(target.id)
        XCTAssertFalse(try list.ids().contains(target.id))
        XCTAssertEqual(try damagedCopies(of: list.fileURL), [damaged])
    }

    private let otherDevice = WriterClaim(
        namespaceId: "other", deviceId: "other-device", deviceName: "Other iPad", claimedAt: Date())

    private func runResult(stop: BackupRunStop?) -> BackupRunResult {
        BackupRunResult(runId: "run", namespaceId: "mine", outcome: .failed, stop: stop)
    }

    private func addATarget() throws -> TargetDescriptor {
        let target = TargetDescriptor(
            id: "damaged-settings-\(UUID().uuidString)", provider: .webdav, label: "Test",
            root: "Empo")
        try BackupTargets.add(target)
        return target
    }

    private func names(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private func damagedCopies(of file: URL) throws -> [Data] {
        let prefix = file.deletingPathExtension().lastPathComponent + ".damaged-"
        let directory = file.deletingLastPathComponent()
        return try names(in: directory).filter { $0.hasPrefix(prefix) }.sorted().map {
            try Data(contentsOf: directory.appendingPathComponent($0))
        }
    }
}

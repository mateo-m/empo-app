// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

final class DataDirectoryTests: XCTestCase {
    private let fm = FileManager.default
    private var documents: URL!
    private var storage: URL!

    override func setUpWithError() throws {
        let folder = fm.temporaryDirectory.appendingPathComponent("DataDirectoryTests-\(UUID().uuidString)")
        documents = folder.appendingPathComponent("Documents", isDirectory: true)
        storage = folder.appendingPathComponent("File Provider Storage", isDirectory: true)
        for name in ["Data/Game", "Games/Game", "Fonts", "Profiles"] {
            try fm.createDirectory(
                at: documents.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("save".utf8).write(to: documents.appendingPathComponent("Data/Game/Save1.rxdata"))
        try fm.createDirectory(at: storage, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let folder = documents.deletingLastPathComponent()
        for case let url as URL in fm.enumerator(at: folder, includingPropertiesForKeys: nil) ?? .init() {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try fm.removeItem(at: folder)
    }

    func testFirstMoveMovesEveryItem() throws {
        XCTAssertNil(DataDirectory.moveAll(of: documents, to: storage))

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: documents.path), [])
        XCTAssertEqual(
            try Set(fm.contentsOfDirectory(atPath: storage.path)), ["Data", "Games", "Fonts", "Profiles"])
        XCTAssertTrue(fm.fileExists(atPath: storage.appendingPathComponent("Data/Game/Save1.rxdata").path))
    }

    func testFirstMoveMovesNothingWhenOneItemCannotMove() throws {
        // A folder without write permission cannot move to another folder.
        // The last item fails, so the others move first and must come back.
        let last = try XCTUnwrap(fm.contentsOfDirectory(atPath: documents.path).last)
        try fm.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: documents.appendingPathComponent(last).path)

        XCTAssertEqual(DataDirectory.moveAll(of: documents, to: storage), last)

        XCTAssertEqual(
            try Set(fm.contentsOfDirectory(atPath: documents.path)), ["Data", "Games", "Fonts", "Profiles"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: storage.path), [])
        XCTAssertTrue(fm.fileExists(atPath: documents.appendingPathComponent("Data/Game/Save1.rxdata").path))
    }

    func testMergeKeepsTheNewerSave() throws {
        try writeOldSaveInStorage()

        XCTAssertNil(DataDirectory.moveAll(of: documents, to: storage))

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: documents.path), [])
        XCTAssertEqual(
            try String(contentsOf: storage.appendingPathComponent("Data/Game/Save1.rxdata")), "save")
        XCTAssertEqual(
            try Set(fm.contentsOfDirectory(atPath: storage.appendingPathComponent("Data/Game").path)),
            ["Save1.rxdata", "Save1.rxdata.empo-displaced.bak"])
    }

    func testMergeMovesNothingWhenOneFileCannotMove() throws {
        try writeOldSaveInStorage()
        // The new save cannot leave a folder without write permission, after
        // the old save already moved aside for it.
        try fm.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: documents.appendingPathComponent("Data/Game").path)

        XCTAssertEqual(DataDirectory.moveAll(of: documents, to: storage), "Data")

        XCTAssertEqual(
            try Set(fm.contentsOfDirectory(atPath: documents.path)), ["Data", "Games", "Fonts", "Profiles"])
        XCTAssertEqual(
            try String(contentsOf: documents.appendingPathComponent("Data/Game/Save1.rxdata")), "save")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: storage.path), ["Data"])
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: storage.appendingPathComponent("Data/Game").path),
            ["Save1.rxdata"])
        XCTAssertEqual(
            try String(contentsOf: storage.appendingPathComponent("Data/Game/Save1.rxdata")), "old")
    }

    private func writeOldSaveInStorage() throws {
        let save = storage.appendingPathComponent("Data/Game/Save1.rxdata")
        try fm.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: save)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: save.path)
    }
}

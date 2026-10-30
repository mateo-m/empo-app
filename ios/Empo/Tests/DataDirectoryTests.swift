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
        let names =
            try fm.contentsOfDirectory(atPath: documents.path) + fm.contentsOfDirectory(atPath: storage.path)
        for url in names.flatMap({
            [documents.appendingPathComponent($0), storage.appendingPathComponent($0)]
        }) {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try fm.removeItem(at: documents.deletingLastPathComponent())
    }

    func testFirstMoveMovesEveryItem() throws {
        XCTAssertTrue(DataDirectory.moveAll(of: documents, to: storage))

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

        XCTAssertFalse(DataDirectory.moveAll(of: documents, to: storage))

        XCTAssertEqual(
            try Set(fm.contentsOfDirectory(atPath: documents.path)), ["Data", "Games", "Fonts", "Profiles"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: storage.path), [])
        XCTAssertTrue(fm.fileExists(atPath: documents.appendingPathComponent("Data/Game/Save1.rxdata").path))
    }
}

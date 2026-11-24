// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

final class ArchiveExtractorTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // EMPO-APP-45: BLACK SOULS could not find "Audio/BGM/タイトル、アリス".
    func testAZipFromAJapaneseWindowsPCKeepsItsJapaneseNames() throws {
        try ArchiveExtractor.extract(archive: fixture("shift-jis-names"), to: scratch)

        assertFiles([
            "ブラックソウルズ/Game.ini",
            "ブラックソウルズ/Audio/BGM/タイトル、アリス.mp3",
            "ブラックソウルズ/Audio/SE/鎖.mp3",
        ])
    }

    func testAZipFromAChineseWindowsPCKeepsItsChineseNames() throws {
        try ArchiveExtractor.extract(archive: fixture("gbk-names"), to: scratch)

        assertFiles(["黑魂/Audio/BGM/标题.ogg", "黑魂/存档/存档01.rvdata2"])
    }

    func testTheImportProbeReadsTheSameJapaneseNames() throws {
        var paths: [String] = []
        try ArchiveExtractor.extractSelective(
            archive: fixture("shift-jis-names"),
            to: scratch,
            onEntry: { path, _ in paths.append(path) },
            include: { $0.hasSuffix(".ini") }
        )

        XCTAssertEqual(
            Set(paths),
            [
                "ブラックソウルズ/Game.ini",
                "ブラックソウルズ/Audio/BGM/タイトル、アリス.mp3",
                "ブラックソウルズ/Audio/SE/鎖.mp3",
            ])
        assertFiles(["ブラックソウルズ/Game.ini"])
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "zip"))
    }

    private func assertFiles(_ paths: [String], file: StaticString = #filePath, line: UInt = #line) {
        for path in paths {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: scratch.appendingPathComponent(path).path),
                "\(path) is missing",
                file: file,
                line: line
            )
        }
    }
}

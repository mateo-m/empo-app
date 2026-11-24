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

    // The GBK bytes of 隆 are also the UTF-8 bytes of ¡. 说明 has the UTF-8 flag.
    func testAChineseNameThatIsAlsoValidUTF8KeepsItsChineseName() throws {
        try ArchiveExtractor.extract(archive: fixture("gbk-mixed-names"), to: scratch)

        assertFiles(["隆.txt", "黑魂/说明.txt", "黑魂/Audio/BGM/标题.ogg"])
    }

    func testAJapaneseNameWithTheBackslashByteKeepsItsNameAtTheTop() throws {
        try ArchiveExtractor.extract(archive: fixture("shift-jis-root-name"), to: scratch)

        assertFiles(["ソフト説明.txt", "ブラックソウルズ/Game.ini"])
    }

    func testAZipFromARussianWindowsPCKeepsAllItsFilesInOneFolder() throws {
        try ArchiveExtractor.extract(archive: fixture("cp1251-names"), to: scratch)

        let folders = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertEqual(folders.count, 1, "\(folders)")
        let files = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: scratch.path))
        XCTAssertTrue(files.contains { $0.hasSuffix("/Game.ini") }, "\(files)")
        XCTAssertTrue(files.contains { $0.hasSuffix(".txt") }, "\(files)")
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

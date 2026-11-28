// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import XCTest

@testable import GameProbe

final class RTPImportTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RTPImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeFolder(_ name: String, files: [String]) throws -> URL {
        let folder = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            let url = folder.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.utf8).write(to: url)
        }
        return folder
    }

    private func relativeFiles(in folder: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            files.append(
                String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1)))
        }
        return files.sorted()
    }

    private func assertFailure(_ expected: RTPImport.Failure, from source: URL, line: UInt = #line) {
        let destination = tempRoot.appendingPathComponent("copy-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try RTPImport.copy(from: source, to: destination), line: line) { error in
            XCTAssertEqual(error as? RTPImport.Failure, expected, line: line)
        }
    }

    // MARK: - Package names

    func testPackageReadsTheGameINIValueInAnyCase() {
        XCTAssertEqual(RTPPackage(gameINIValue: "RPGVXAce"), .vxAce)
        XCTAssertEqual(RTPPackage(gameINIValue: " rpgvx "), .vx)
        XCTAssertEqual(RTPPackage(gameINIValue: "STANDARD"), .xp)
        XCTAssertNil(RTPPackage(gameINIValue: "MyOwnRTP"))
    }

    func testPackageDetectsTheVersionFromItsGraphicsFolders() {
        XCTAssertEqual(RTPPackage.detect(graphicsFolders: ["Faces", "Titles1", "System"]), .vxAce)
        XCTAssertEqual(RTPPackage.detect(graphicsFolders: ["windowskins", "Icons"]), .xp)
        XCTAssertEqual(RTPPackage.detect(graphicsFolders: ["Faces", "System"]), .vx)
        XCTAssertNil(RTPPackage.detect(graphicsFolders: ["Pictures"]))
    }

    func testKnownPackagesSkipUnknownNamesAndDuplicates() throws {
        let requirement = try requirement(rtp: ["RPGVXAce", "rpgvxace", "MyOwnRTP", "Standard"])
        XCTAssertEqual(requirement.knownPackages, [.vxAce, .xp])
    }

    func testMissingNamesKeepUnknownNamesAndSkipInstalledOnes() throws {
        let requirement = try requirement(rtp: ["RPGVXAce", "rpgvxace", "MyOwnRTP", "Standard"])
        XCTAssertEqual(
            requirement.missingNames(isInstalled: { _ in false }),
            ["RPG Maker VX Ace", "MyOwnRTP", "RPG Maker XP"])
        XCTAssertEqual(requirement.missingNames(isInstalled: { _ in true }), ["MyOwnRTP"])
        XCTAssertEqual(
            requirement.missingNames(isInstalled: { $0 == .xp }), ["RPG Maker VX Ace", "MyOwnRTP"])
    }

    private func requirement(rtp values: [String]) throws -> GameRTPRequirement {
        let game = try makeFolder("Game-\(UUID().uuidString)", files: [])
        let keys = ["RTP", "RTP1", "RTP2", "RTP3"]
        let ini = zip(keys, values).map { "\($0)=\($1)" }.joined(separator: "\n")
        try "[Game]\n\(ini)\n".write(
            to: game.appendingPathComponent("Game.ini"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(GameRTPRequirement.detect(at: game))
    }

    // MARK: - Installer paths

    func testMediaPathKeepsOnlyTheMediaFoldersOfTheApp() {
        XCTAssertEqual(RTPImport.mediaPath("{app}/Audio/SE/Decision2.ogg"), ["Audio", "SE", "Decision2.ogg"])
        XCTAssertEqual(RTPImport.mediaPath("{APP}/graphics/Titles1/a.png"), ["graphics", "Titles1", "a.png"])
        XCTAssertEqual(RTPImport.mediaPath("{app}/Fonts/a.ttf"), ["Fonts", "a.ttf"])
        XCTAssertNil(RTPImport.mediaPath("{app}/Game.exe"))
        XCTAssertNil(RTPImport.mediaPath("{app}/Audio"))
        XCTAssertNil(RTPImport.mediaPath("{sys}/Audio/SE/a.ogg"))
        XCTAssertNil(RTPImport.mediaPath("{app}/Data/Scripts.rvdata2"))
    }

    func testMediaPathRefusesPartsThatLeaveTheFolder() {
        XCTAssertNil(RTPImport.mediaPath("{app}/Audio/../../a.ogg"))
        XCTAssertNil(RTPImport.mediaPath("{app}/Audio/./a.ogg"))
        XCTAssertNil(RTPImport.mediaPath("{app}/Audio//a.ogg"))
        XCTAssertNil(RTPImport.mediaPath("{app}/Audio/SE/"))
    }

    // MARK: - Folder import

    func testFolderImportCopiesOnlyTheMediaFolders() throws {
        let rtp = try makeFolder(
            "RPGVXAce",
            files: [
                "Audio/SE/Decision2.ogg", "Graphics/Titles1/Book.png", "Fonts/Font.ttf",
                "Uninstall/unins000.exe", "readme.txt", "Audio/.DS_Store", "Graphics/.cache/a.png",
            ])
        let destination = tempRoot.appendingPathComponent("copy", isDirectory: true)

        XCTAssertEqual(try RTPImport.copy(from: rtp, to: destination), .vxAce)
        XCTAssertEqual(
            relativeFiles(in: destination),
            ["Audio/SE/Decision2.ogg", "Fonts/Font.ttf", "Graphics/Titles1/Book.png"])
    }

    func testFolderImportLeavesOutLinks() throws {
        let outside = try makeFolder("Outside", files: ["secret.txt", "Pictures/a.png"])
        let rtp = try makeFolder(
            "RPGVXAce",
            files: ["Audio/SE/Decision2.ogg", "Graphics/Titles1/Book.png", "Graphics/Faces/a.png"])
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(
            at: rtp.appendingPathComponent("Audio/SE/Link.ogg"),
            withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try fileManager.createSymbolicLink(
            at: rtp.appendingPathComponent("Graphics/Pictures"),
            withDestinationURL: outside.appendingPathComponent("Pictures"))
        try fileManager.createSymbolicLink(
            at: rtp.appendingPathComponent("Fonts"), withDestinationURL: outside)
        let destination = tempRoot.appendingPathComponent("copy", isDirectory: true)

        XCTAssertEqual(try RTPImport.copy(from: rtp, to: destination), .vxAce)
        XCTAssertEqual(
            relativeFiles(in: destination),
            ["Audio/SE/Decision2.ogg", "Graphics/Faces/a.png", "Graphics/Titles1/Book.png"])
    }

    func testFolderImportFindsTheRTPOneLevelDown() throws {
        let parent = try makeFolder(
            "RGSS",
            files: ["Standard/Audio/SE/001-System01.ogg", "Standard/Graphics/Windowskins/001-Blue01.png"])
        let destination = tempRoot.appendingPathComponent("copy", isDirectory: true)

        XCTAssertEqual(try RTPImport.copy(from: parent, to: destination), .xp)
        XCTAssertEqual(
            relativeFiles(in: destination),
            ["Audio/SE/001-System01.ogg", "Graphics/Windowskins/001-Blue01.png"])
    }

    func testFolderImportRefusesAGameFolder() throws {
        assertFailure(
            .notRPGMakerFiles,
            from: try makeFolder("WithINI", files: ["Game.ini", "Audio/SE/a.ogg", "Graphics/Faces/a.png"]))
        assertFailure(
            .notRPGMakerFiles,
            from: try makeFolder(
                "WithData", files: ["Data/Map001.rvdata", "Audio/SE/a.ogg", "Graphics/Faces/a.png"]))
    }

    func testFolderImportRefusesAFolderWithoutAnRTP() throws {
        assertFailure(.notRPGMakerFiles, from: try makeFolder("Photos", files: ["a.png", "b/c.png"]))
        assertFailure(.notRPGMakerFiles, from: try makeFolder("NoAudio", files: ["Graphics/Faces/a.png"]))
        assertFailure(
            .notRPGMakerFiles,
            from: try makeFolder("Unknown", files: ["Audio/a.ogg", "Graphics/Other/a.png"]))
    }

    // MARK: - Installer import

    func testInstallerImportRefusesAFileThatIsNotAnInstaller() throws {
        let folder = try makeFolder("Downloads", files: ["notes.txt"])
        assertFailure(.notRPGMakerFiles, from: folder.appendingPathComponent("notes.txt"))

        let fake = folder.appendingPathComponent("Setup.exe")
        try Data("MZ".utf8).write(to: fake)
        assertFailure(.notRPGMakerFiles, from: fake)

        let empty = folder.appendingPathComponent("Empty.exe")
        try Data().write(to: empty)
        assertFailure(.notRPGMakerFiles, from: empty)
    }

    func testInstallerReaderRefusesAPEFileWithoutTheSetupResource() throws {
        var pe = Data(count: 0x200)
        pe.replaceSubrange(0..<2, with: Data("MZ".utf8))
        pe.replaceSubrange(0x3c..<0x40, with: [0x80, 0, 0, 0])
        pe.replaceSubrange(0x80..<0x84, with: [0x50, 0x45, 0, 0])
        let url = tempRoot.appendingPathComponent("Other.exe")
        try pe.write(to: url)

        XCTAssertThrowsError(try InnoSetupArchive(contentsOf: url)) { error in
            XCTAssertEqual(error as? InnoSetupArchive.Failure, .notAnInstaller)
        }
    }

    func testFolderWithOnlyAnUnrelatedInstallerIsNotRPGMakerFiles() throws {
        let folder = try makeFolder("Installers", files: ["other/readme.txt"])
        try Data("MZ".utf8).write(to: folder.appendingPathComponent("other/Setup.exe"))
        assertFailure(.notRPGMakerFiles, from: folder)
    }

    func testInstallerImportCopiesTheMediaFilesInTheEnglishVersion() throws {
        let installer = try makeInstaller(files: [
            .init(path: #"{app}\Audio\SE\Decision2.ogg"#, languages: "japanese", data: "ja"),
            .init(path: #"{app}\Audio\SE\Decision2.ogg"#, languages: "english", data: "en"),
            .init(path: #"{app}\Graphics\Titles1\Book.png"#, languages: "", data: "png"),
            .init(path: #"{app}\Game.exe"#, languages: "", data: "exe"),
        ])
        let destination = tempRoot.appendingPathComponent("copy", isDirectory: true)

        XCTAssertEqual(try RTPImport.copy(from: installer, to: destination), .vxAce)
        XCTAssertEqual(
            relativeFiles(in: destination), ["Audio/SE/Decision2.ogg", "Graphics/Titles1/Book.png"])
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("Audio/SE/Decision2.ogg"), encoding: .utf8),
            "en")
    }

    func testInstallerImportRefusesAChangedOrCutInstaller() throws {
        let installer = try makeInstaller(files: Self.storedFiles)
        var bytes = try Data(contentsOf: installer)

        var changed = bytes
        changed[changed.count - 1] ^= 0xff
        try changed.write(to: installer)
        assertFailure(.damaged, from: installer)

        bytes.removeLast(2)
        try bytes.write(to: installer)
        assertFailure(.damaged, from: installer)
    }

    func testFolderImportKeepsNoFilesOfADamagedInstallerBeforeAGoodOne() throws {
        let damaged = try makeInstaller(files: Self.storedFiles)
        var bytes = try Data(contentsOf: damaged)
        bytes[bytes.count - 1] ^= 0xff
        try bytes.write(to: damaged)
        let good = try makeInstaller(files: [
            .init(path: #"{app}\Audio\SE\Decision2.ogg"#, languages: "", data: "en"),
            .init(path: #"{app}\Graphics\Titles1\Book.png"#, languages: "", data: "png"),
        ])
        let folder = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: damaged.deletingLastPathComponent(), to: folder.appendingPathComponent("A"))
        try FileManager.default.moveItem(
            at: good.deletingLastPathComponent(), to: folder.appendingPathComponent("B"))
        let destination = tempRoot.appendingPathComponent("copy", isDirectory: true)

        XCTAssertEqual(try RTPImport.copy(from: folder, to: destination), .vxAce)
        XCTAssertEqual(
            relativeFiles(in: destination), ["Audio/SE/Decision2.ogg", "Graphics/Titles1/Book.png"])
    }

    func testCopyNeedsItsAudioAndGraphicsFolders() throws {
        let copy = try makeFolder("RPGVXAce", files: ["Audio/SE/a.ogg", "Graphics/Titles1/b.png"])
        XCTAssertTrue(RTPImport.isCopy(at: copy))
        XCTAssertFalse(RTPImport.isCopy(at: try makeFolder("Empty", files: [])))
        XCTAssertFalse(RTPImport.isCopy(at: try makeFolder("OnlyAudio", files: ["Audio/SE/a.ogg"])))
        let emptied = try makeFolder("Emptied", files: [])
        for name in ["Audio/SE", "Graphics/Titles1"] {
            try FileManager.default.createDirectory(
                at: emptied.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertFalse(RTPImport.isCopy(at: emptied))
        let file = tempRoot.appendingPathComponent("RPGVX")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(RTPImport.isCopy(at: file))
        XCTAssertFalse(RTPImport.isCopy(at: tempRoot.appendingPathComponent("Missing")))
    }

    func testInstallerImportRefusesAnInstallerWithoutAnRTP() throws {
        assertFailure(
            .notRPGMakerFiles,
            from: try makeInstaller(files: [
                .init(path: #"{app}\Audio\a.ogg"#, languages: "", data: "a"),
                .init(path: #"{app}\Readme.txt"#, languages: "", data: "b"),
            ]))
    }

    func testInstallerImportReadsLzmaBlocksAndAnLzmaChunk() throws {
        let installer = try makeInstaller(
            files: Self.lzmaFiles, data: .lzma(try Self.stream(Self.lzmaChunk)),
            blockStreams: (try Self.stream(Self.lzmaHeader), try Self.stream(Self.lzmaEntries)))
        let destination = tempRoot.appendingPathComponent("copy", isDirectory: true)

        XCTAssertEqual(try RTPImport.copy(from: installer, to: destination), .vx)
        XCTAssertEqual(
            relativeFiles(in: destination), ["Audio/SE/Decision1.ogg", "Graphics/Faces/Actor1.png"])
        for (path, file) in zip(
            ["Audio/SE/Decision1.ogg", "Graphics/Faces/Actor1.png"], Self.lzmaFiles.dropFirst())
        {
            XCTAssertEqual(
                try String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8), file.data)
        }
    }

    func testInstallerImportRefusesACutLzmaChunk() throws {
        let stream = try Self.stream(Self.lzmaChunk)
        assertFailure(
            .damaged,
            from: try makeInstaller(files: Self.lzmaFiles, data: .lzma(stream.prefix(stream.count / 2))))
    }

    func testLzmaDecoderRefusesAStreamLongerThanTheLimit() throws {
        let decoder = try LzmaRawDecoder(stream: try Self.stream(Self.lzmaChunk))
        XCTAssertThrowsError(try decoder.readAll(limit: 1000)) { error in
            XCTAssertEqual(error as? InnoSetupArchive.Failure, .damaged)
        }
    }

    func testInstallerImportReadsTheDataFileNextToTheInstaller() throws {
        let installer = try makeInstaller(files: Self.storedFiles, data: .separateFile)
        let destination = tempRoot.appendingPathComponent("copy", isDirectory: true)

        XCTAssertEqual(try RTPImport.copy(from: installer, to: destination), .vx)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("Audio/SE/Decision1.ogg"), encoding: .utf8),
            "sound")
    }

    func testInstallerImportNeedsTheDataFileNextToTheInstaller() throws {
        let installer = try makeInstaller(files: Self.storedFiles, data: .separateFile)
        try FileManager.default.removeItem(
            at: installer.deletingLastPathComponent().appendingPathComponent("Setup-1.bin"))
        assertFailure(.missingDataFile, from: installer)
    }

    // MARK: - Fake installer

    private static let storedFiles: [FakeInstallerFile] = [
        .init(path: #"{app}\Audio\SE\Decision1.ogg"#, languages: "", data: "sound"),
        .init(path: #"{app}\Graphics\Faces\Actor1.png"#, languages: "", data: "face"),
    ]

    /// Each file is larger than one read of the reader, and the reader
    /// skips the first file.
    private static let lzmaFiles: [FakeInstallerFile] = [
        .init(path: #"{app}\Game.exe"#, languages: "", data: String(repeating: "Game ", count: 14000)),
        .init(
            path: #"{app}\Audio\SE\Decision1.ogg"#, languages: "",
            data: String(repeating: "Audio ", count: 12000)),
        .init(
            path: #"{app}\Graphics\Faces\Actor1.png"#, languages: "",
            data: String(repeating: "Faces ", count: 12000)),
    ]

    // Swift has no LZMA encoder on Linux. These are the streams of the
    // `lzmaFiles` chunk and of its two blocks, from Python:
    // `bytes([0x5d]) + (1 << 16).to_bytes(4, "little") + lzma.compress(
    // data, format=lzma.FORMAT_RAW, filters=[{"id": lzma.FILTER_LZMA1,
    // "dict_size": 1 << 16}])`.
    private static let lzmaChunk =
        "XQAAAQAAI5hJpmdHLj4dO3RtCSlnaFmsE7tBaG9uoqNQQLbDhGGNvzev2r321RQPeLIfwNDS4Z84P/8Q1aYUlYDJJwHORRwuhLsJqr/5TpHmXpv3MMGW8cDyLm1NabAMA5GFWGWwe24zKxkGzu27bfPzCvtvBVHV0XzGYK+TkrKRmRf//kN4AA=="
    private static let lzmaHeader =
        "XQAAAQAAAG9ARoQwn4/OmCIlqYsdj6OHP0aXX8YEEe5i3fLFiLgS4DvC9FuJx+XS5+CouHkuhMxDnyOLFYkNW2Jyq2n+YgE3VvZYbXIvt4svSLFB2wulg6gKlyru8jhZAQLGDtif/5KJIoA="
    private static let lzmaEntries =
        "XQAAAQAAAG4At/7AWeU8oVVhzk59WMslgwq/Wetx6pGf+Qd7FmFpBHv9tbENb9rBxEoBc9vEO96lnNGts37oAyoOGY6807XN4E/bcvXr719+9ZjvJ1QeqQRvOBskGNhFbWkT9gUqfXeP///f5QAA"

    private static func stream(_ base64: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: base64))
    }

    private enum FakeData {
        case inside
        case lzma(Data)
        case separateFile
    }

    private struct FakeInstallerFile {
        let path: String
        let languages: String
        let data: String
    }

    /// An Inno Setup 5.4.2 installer with one chunk. Each field that the
    /// reader skips is zero bytes, which reads as an empty string or a
    /// zero number.
    private func makeInstaller(
        files: [FakeInstallerFile], data: FakeData = .inside,
        blockStreams: (header: Data, entries: Data)? = nil
    ) throws -> URL {
        var lzmaStream: Data?
        if case .lzma(let stream) = data { lzmaStream = stream }
        var isSeparate = false
        if case .separateFile = data { isSeparate = true }
        var header = Data(count: 12 * 4)
        header.appendString("")
        header.append(Data(count: 17 * 4 + 32))
        var counts = [UInt32](repeating: 0, count: 16)
        counts[7] = UInt32(files.count)
        counts[8] = UInt32(files.count)
        for count in counts { header.appendU32(count) }
        header.append(Data(count: 32 + 28 + 8))
        header.appendU32(1)
        header.append(Data(count: 5))
        header.append(lzmaStream == nil ? 0 : 3)
        header.append(Data(count: 2 + 2 + 4 + 6))
        for (location, file) in files.enumerated() {
            header.append(Data(count: 4))
            header.appendString(file.path)
            header.append(Data(count: 4 * 4))
            header.appendString(file.languages)
            header.append(Data(count: 3 * 4 + 20))
            header.appendU32(UInt32(location))
            header.append(Data(count: 19))
        }

        let contents = files.map { Data($0.data.utf8) }
        let chunk = Data("zlb\u{1a}".utf8) + (lzmaStream ?? contents.reduce(Data(), +))
        let chunkSize = chunk.count - 4
        var entries = Data()
        var offset = 0
        for content in contents {
            entries.append(Data(count: 8))
            // A data file starts with its own 12-byte header.
            entries.appendU32(isSeparate ? 12 : 0)
            entries.appendU64(UInt64(offset))
            entries.appendU64(UInt64(content.count))
            entries.appendU64(UInt64(chunkSize))
            var digest = FileDigest(md5: false)
            content.withUnsafeBytes { digest.update($0) }
            entries.append(digest.finalize())
            entries.append(Data(count: 16))
            entries.append(contentsOf: [lzmaStream == nil ? 0 : 0x80, 0])
            offset += content.count
        }

        let resource = 0x200
        let loader = resource + 0x60
        let setup = 0x300
        var setupData = Data("Inno Setup Setup Data (5.4.2)".utf8)
        setupData.append(Data(count: 64 - setupData.count))
        if let blockStreams {
            for (stream, plain) in [(blockStreams.header, header), (blockStreams.entries, entries)] {
                XCTAssertEqual(
                    try LzmaRawDecoder(stream: stream).readAll(limit: 1 << 20), plain,
                    "The block changed, so make its stream again")
                setupData.append(block(stream, isCompressed: true))
            }
        } else {
            setupData.append(block(header))
            setupData.append(block(entries))
        }
        let dataOffset = setup + setupData.count

        var exe = Data(count: setup)
        exe.replace(at: 0, with: Data("MZ".utf8))
        exe.replace(at: 0x3c, u32: 0x80)
        exe.replace(at: 0x80, with: Data([0x50, 0x45, 0, 0]))
        exe.replace(at: 0x86, u16: 1)
        exe.replace(at: 0x94, u16: 120)
        exe.replace(at: 0x98, u16: 0x10b)
        exe.replace(at: 0x98 + 92, u32: 3)
        exe.replace(at: 0x98 + 96 + 16, u32: 0x1000)
        let section = 0x98 + 120
        exe.replace(at: section + 8, u32: 0x1000)
        exe.replace(at: section + 12, u32: 0x1000)
        exe.replace(at: section + 20, u32: UInt32(resource))
        for (directory, id, target) in [(0, 10, 0x8000_0018), (0x18, 11111, 0x8000_0030), (0x30, 1033, 0x48)]
        {
            exe.replace(at: resource + directory + 14, u16: 1)
            exe.replace(at: resource + directory + 16, u32: UInt32(id))
            exe.replace(at: resource + directory + 20, u32: UInt32(target))
        }
        exe.replace(at: resource + 0x48, u32: UInt32(0x1000 + loader - resource))

        var table = Data("rDlPtS\u{cd}\u{e6}\u{d7}{\u{0b}*".unicodeScalars.map { UInt8($0.value) })
        table.appendU32(1)
        table.append(Data(count: 16))
        table.appendU32(UInt32(setup))
        table.appendU32(isSeparate ? 0 : UInt32(dataOffset))
        table.appendU32(RawDeflate.crc32(table))
        exe.replace(at: loader, with: table)

        exe.append(setupData)
        let url = tempRoot.appendingPathComponent("Installer-\(UUID().uuidString)/Setup.exe")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isSeparate {
            var slice = Data("idska32\u{1a}".utf8)
            slice.appendU32(UInt32(12 + chunk.count))
            slice.append(chunk)
            try slice.write(to: url.deletingLastPathComponent().appendingPathComponent("Setup-1.bin"))
        } else {
            exe.append(chunk)
        }
        try exe.write(to: url)
        return url
    }

    /// A CRC-checked size and kind, then 4 KiB pieces with their own CRC.
    private func block(_ content: Data, isCompressed: Bool = false) -> Data {
        var pieces = Data()
        var start = content.startIndex
        while start < content.endIndex {
            let piece = content[start..<min(start + 4096, content.endIndex)]
            pieces.appendU32(RawDeflate.crc32(Data(piece)))
            pieces.append(piece)
            start = piece.endIndex
        }
        var sizeAndKind = Data()
        sizeAndKind.appendU32(UInt32(pieces.count))
        sizeAndKind.append(isCompressed ? 1 : 0)
        var block = Data()
        block.appendU32(RawDeflate.crc32(sizeAndKind))
        block.append(sizeAndKind)
        block.append(pieces)
        return block
    }
}

extension Data {
    fileprivate mutating func appendU32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendU64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendString(_ text: String) {
        let bytes = Data(text.utf8)
        appendU32(UInt32(bytes.count))
        append(bytes)
    }

    fileprivate mutating func replace(at offset: Int, with bytes: Data) {
        replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }

    fileprivate mutating func replace(at offset: Int, u16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replace(at: offset, with: Data($0)) }
    }

    fileprivate mutating func replace(at offset: Int, u32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replace(at: offset, with: Data($0)) }
    }
}

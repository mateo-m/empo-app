import Foundation
import XCTest

@testable import GameProbe

final class PortableGameSavesTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    private let marshalBytes = Data([0x04, 0x08, 0x7B, 0x00])
    private let textBytes = Data("just text".utf8)

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("portable-saves-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ data: Data, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testMissingRootYieldsNothing() {
        let gone = root.appendingPathComponent("missing")
        XCTAssertEqual(PortableGameSaves.entryNames(atGameRoot: gone), [])
    }

    func testRootSaveExtensionsDetectedRegardlessOfStem() throws {
        // Stems vary across games (Essentials, Uranium, Insurgence,
        // localized Japanese stems). The extension is the stable part.
        try write(marshalBytes, to: "Game.rxdata")
        try write(marshalBytes, to: "Uranium_1.rxdata")
        try write(marshalBytes, to: "save_0_backup_1.rxdata")
        try write(marshalBytes, to: "セーブ A.rxdata")
        try write(marshalBytes, to: "Save01.rvdata2")
        // A truncated backup stays a rescue candidate by NAME.
        try write(Data(), to: "Game.rxdata.bak")
        try write(textBytes, to: "readme.txt")
        try write(textBytes, to: "Game.ini")

        XCTAssertEqual(
            PortableGameSaves.entryNames(atGameRoot: root),
            [
                "Game.rxdata", "Game.rxdata.bak", "Save01.rvdata2",
                "Uranium_1.rxdata", "save_0_backup_1.rxdata", "セーブ A.rxdata",
            ])
    }

    func testMarshalMagicDetectsRenamedSavesWithForeignExtensions() throws {
        // `.bin` carries no name signal, so the magic alone decides.
        try write(marshalBytes, to: "progress.bin")
        try write(textBytes, to: "settings.bin")

        XCTAssertEqual(
            PortableGameSaves.entryNames(atGameRoot: root),
            ["progress.bin"])
    }

    func testEngineDirectoriesAreNeverEntered() throws {
        // Data/*.rxdata are Marshal game assets, not saves.
        try write(marshalBytes, to: "Data/Scripts.rxdata")
        try write(marshalBytes, to: "Graphics/weird.rxdata")
        try write(marshalBytes, to: "Audio/pack.bin")

        XCTAssertEqual(PortableGameSaves.entryNames(atGameRoot: root), [])
    }

    func testNamedSaveFoldersDetectedEvenWhenEmptyOrOpaque() throws {
        for name in ["Save", "Saves", "Save Data", "SaveData", "Save Game"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true)
        }

        XCTAssertEqual(
            PortableGameSaves.entryNames(atGameRoot: root),
            ["Save", "Save Data", "Save Game", "SaveData", "Saves"])
    }

    func testUnnamedFolderDetectedByProbingItsContents() throws {
        // A localized or renamed save folder has no recognizable
        // name. A Marshal-shaped child gives it away.
        try write(marshalBytes, to: "セーブデータ/slot1.dat")
        try write(textBytes, to: "Mods/readme.txt")

        XCTAssertEqual(
            PortableGameSaves.entryNames(atGameRoot: root),
            ["セーブデータ"])
    }

    func testFolderProbeChecksImmediateChildrenOnly() throws {
        // The probe is shallow by design: nested Marshal files do
        // not mark the top-level folder.
        try write(marshalBytes, to: "Stuff/inner/deep.rxdata2unknown")
        try write(textBytes, to: "Stuff/notes.txt")

        XCTAssertEqual(PortableGameSaves.entryNames(atGameRoot: root), [])
    }

    func testHasMarshalMagicBoundaries() throws {
        try write(Data([0x04]), to: "one-byte")
        try write(Data([0x04, 0x08]), to: "exact")
        try write(Data([0x08, 0x04, 0x00]), to: "swapped")
        XCTAssertFalse(
            PortableGameSaves.hasMarshalMagic(root.appendingPathComponent("one-byte")))
        XCTAssertTrue(
            PortableGameSaves.hasMarshalMagic(root.appendingPathComponent("exact")))
        XCTAssertFalse(
            PortableGameSaves.hasMarshalMagic(root.appendingPathComponent("swapped")))
    }

    func testNearMissMagicBytesAreExcluded() throws {
        // 0x04 0x07 is one off the Marshal version magic.
        try write(Data([0x04, 0x07]), to: "almost.bin")

        XCTAssertEqual(PortableGameSaves.entryNames(atGameRoot: root), [])
    }

    func testEmptyFilesFallBackToTheNameSignal() throws {
        // An empty file has no magic to read. Only a name signal
        // keeps it: the RGSS family, or the generic save names SPEC
        // 3.6 added. A truncated save is still a rescue candidate by
        // name.
        try write(Data(), to: "empty.bin")
        try write(Data(), to: "empty.sav")
        try write(Data(), to: "empty.rxdata")

        XCTAssertFalse(
            PortableGameSaves.hasMarshalMagic(root.appendingPathComponent("empty.sav")))
        XCTAssertEqual(
            PortableGameSaves.entryNames(atGameRoot: root),
            ["empty.rxdata", "empty.sav"])
    }

    func testUnreadableFilesFallBackToTheNameSignal() throws {
        // The magic probe cannot open an unreadable file, so only
        // the save-family extension keeps it.
        try write(marshalBytes, to: "locked.bin")
        try write(marshalBytes, to: "locked.rxdata")
        for name in ["locked.bin", "locked.rxdata"] {
            try fm.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: root.appendingPathComponent(name).path)
        }
        defer {
            for name in ["locked.bin", "locked.rxdata"] {
                try? fm.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: root.appendingPathComponent(name).path)
            }
        }
        if (try? FileHandle(forReadingFrom: root.appendingPathComponent("locked.bin"))) != nil {
            // Root ignores POSIX permission bits (CI containers can
            // run as root), so the failure cannot be provoked.
            try skipOrFail("0o000 file is still readable, likely running as root")
        }

        XCTAssertEqual(
            PortableGameSaves.entryNames(atGameRoot: root),
            ["locked.rxdata"])
    }

    func testFileNamedLikeASaveFolderIsExcluded() throws {
        // The folder-name list applies to DIRECTORIES only. A plain
        // file named "Save Data" carries no extension, no magic, and
        // no stem from the generic list of SPEC 3.6.
        try write(textBytes, to: "Save Data")

        XCTAssertEqual(PortableGameSaves.entryNames(atGameRoot: root), [])
    }

    func testFolderNameMatchingIgnoresCase() throws {
        // "SAVE" matches the save-folder list. "DATA" matches the
        // engine list and is never entered.
        try write(marshalBytes, to: "SAVE/slot1.rxdata")
        try write(marshalBytes, to: "DATA/Scripts.rxdata")

        XCTAssertEqual(PortableGameSaves.entryNames(atGameRoot: root), ["SAVE"])
    }

    func testDanglingSymlinkAtRootIsExcluded() throws {
        try write(marshalBytes, to: "Game.rxdata")
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("ghost"),
            withDestinationURL: root.appendingPathComponent("missing-target"))

        XCTAssertEqual(PortableGameSaves.entryNames(atGameRoot: root), ["Game.rxdata"])
    }

    func testSaveFolderNestedInsideAnEngineDirectoryIsExcluded() throws {
        // Engine directories are never entered, even to find a
        // conventional save folder inside.
        try write(marshalBytes, to: "Data/Save/x.rxdata")

        XCTAssertEqual(PortableGameSaves.entryNames(atGameRoot: root), [])
    }

    func testDecomposedFolderNameDetectedByProbe() throws {
        // The folder name arrives in NFD (decomposed) form, as
        // Darwin filesystems commonly return names. The assertion
        // compares with String ==, which uses canonical
        // equivalence, so it holds whether the listing returns NFD
        // or NFC.
        let decomposed = "Se\u{0301}curite\u{0301}"  // "Sécurité", NFD
        try write(marshalBytes, to: "\(decomposed)/slot1.dat")

        let names = PortableGameSaves.entryNames(atGameRoot: root)
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names.first, "S\u{00E9}curit\u{00E9}")  // "Sécurité", NFC
    }
}

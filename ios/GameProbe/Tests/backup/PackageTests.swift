import Foundation
import XCTest

@testable import GameProbe

/// The backup package of SPEC 12: the ZIP64 writer, the layout, the
/// manifest, the checks, and the two doors.
final class PackageTests: XCTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    private var root = URL(fileURLWithPath: "/")
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("package-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    private func file(_ name: String, bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private func entry(
        root: EntryRoot = .container, path: String, bytes: Data
    ) -> SnapshotManifest.Entry {
        SnapshotManifest.Entry(
            root: root,
            path: path,
            size: Int64(bytes.count),
            modifiedAt: stamp,
            hash: ContentHash.hex(of: bytes),
            compression: .stored)
    }

    /// One package with one game stream, built by the real export.
    private func writeAPackage(
        files: [(String, Data)] = [("Game/Save01.rvdata2", Data(repeating: 7, count: 4_096))]
    ) throws -> (url: URL, manifest: PackageManifest) {
        let container = root.appendingPathComponent("Games/Quest", isDirectory: true)
        var members: [BackupSetMember] = []
        for (path, bytes) in files {
            _ = try file("Games/Quest/" + path, bytes: bytes)
            members.append(
                BackupSetMember(
                    root: .container, path: path, size: Int64(bytes.count), modifiedAt: stamp))
        }

        let plan = PackagePlan(
            gameName: "Quest",
            streams: [
                PackagePlan.Stream(
                    key: BackupKeys.gameKey(containerFolderName: "Quest"),
                    gameName: "Quest",
                    mode: .slim,
                    containerFolderName: "Quest",
                    versionMarker: .init(),
                    rescuedSavesBuckets: [],
                    members: members,
                    source: MemberSource(container: container))
            ])
        // The staging area sits under the backup root, and the
        // root's own parent is Application Support.
        let localRoot = BackupRootLayout(applicationSupport: root).root
        let record = try plan.build(
            id: "export",
            localRoot: localRoot,
            sourceDevice: "iPad",
            freeSpaceBytes: 1 << 40,
            at: stamp)
        let url = record.zipURL(localRoot: localRoot)
        return (url, try PackageSource(zip: url, packageId: "p1").manifest)
    }

    // MARK: - 1. A stranger's ZIP tool reads it

    func testAWrittenPackageReadsInAnUnrelatedZipTool() throws {
        let bytes = Data((0..<20_000).map { UInt8($0 % 251) })
        let package = try writeAPackage(files: [("Game/Save01.rvdata2", bytes)])

        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        guard fm.isExecutableFile(atPath: unzip.path) else {
            try skipOrFail("this host has no unzip")
        }
        let out = root.appendingPathComponent("out", isDirectory: true)
        let process = Process()
        process.executableURL = unzip
        process.arguments = ["-q", "-o", package.url.path, "-d", out.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let saved = out.appendingPathComponent(
            "Documents/Games/Quest/Game/Save01.rvdata2")
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
        XCTAssertEqual(
            try Data(contentsOf: out.appendingPathComponent(PackageLayout.readmePath)),
            Data(PackageLayout.readmeText.utf8))

        // The two ZIP64 end records, which is what makes the format
        // ZIP64 and not plain ZIP, per 12.1.
        let raw = try Data(contentsOf: package.url)
        XCTAssertTrue(raw.contains(signature(0x0606_4B50)))
        XCTAssertTrue(raw.contains(signature(0x0706_4B50)))
    }

    private func signature(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }

    // MARK: - 2. Over 4 GiB

    /// The 64-bit fields carry a size and an offset that the 32-bit
    /// ones cannot hold.
    ///
    /// The suite writes no 4 GiB file. It proves the same two paths
    /// instead: the writer puts every size in an 8-byte field, and
    /// the reader reads a directory that declares 5 GiB back as 5
    /// GiB and not as a truncated number.
    func testTheZip64FieldsCarryAnEntryOverFourGigabytes() throws {
        let bytes = Data(repeating: 3, count: 1_000)
        let package = try writeAPackage(files: [("Game/Save01.rvdata2", bytes)])
        let raw = try Data(contentsOf: package.url)

        // The local header of the first entry: the two 4-byte size
        // fields read 0xFFFFFFFF, and the ZIP64 extra holds the real
        // numbers.
        let nameLength = Int(raw.u16(26))
        XCTAssertEqual(raw.u32(18), 0xFFFF_FFFF)
        XCTAssertEqual(raw.u32(22), 0xFFFF_FFFF)
        XCTAssertEqual(raw.u16(30 + nameLength), 0x0001)
        XCTAssertEqual(raw.u64(30 + nameLength + 4), 1_000)

        let huge: Int64 = 5 * 1_024 * 1_024 * 1_024
        let file = root.appendingPathComponent("huge.zip")
        try zip64Directory(size: huge, offset: huge).write(to: file)
        let reader = try ZipReader(reading: file)
        defer { reader.close() }
        let entry = try XCTUnwrap(reader.entry(at: "Documents/Games/Quest/Game/big.bin"))
        XCTAssertEqual(entry.uncompressedSize, huge)
        XCTAssertEqual(entry.headerOffset, huge)
    }

    /// A central directory that declares one entry over 4 GiB. It
    /// holds no body, because only the directory decides these two
    /// numbers.
    private func zip64Directory(size: Int64, offset: Int64) -> Data {
        let name = Array("Documents/Games/Quest/Game/big.bin".utf8)
        var extra = Data()
        extra.append(le16: 0x0001)
        extra.append(le16: 24)
        extra.append(le64: size)
        extra.append(le64: size)
        extra.append(le64: offset)

        var out = Data()
        out.append(le32: 0x0201_4B50)
        out.append(le16: 45)
        out.append(le16: 45)
        out.append(le16: 0x0800)
        out.append(le16: 0)
        out.append(le32: 0)
        out.append(le32: 0)
        out.append(le32: 0xFFFF_FFFF)
        out.append(le32: 0xFFFF_FFFF)
        out.append(le16: UInt16(name.count))
        out.append(le16: UInt16(extra.count))
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le32: 0)
        out.append(le32: 0xFFFF_FFFF)
        out.append(contentsOf: name)
        out.append(extra)

        let directorySize = Int64(out.count)
        var file = out
        file.append(le32: 0x0606_4B50)
        file.append(le64: 44)
        file.append(le16: 45)
        file.append(le16: 45)
        file.append(le32: 0)
        file.append(le32: 0)
        file.append(le64: 1)
        file.append(le64: 1)
        file.append(le64: directorySize)
        file.append(le64: 0)
        file.append(le32: 0x0706_4B50)
        file.append(le32: 0)
        file.append(le64: directorySize)
        file.append(le32: 1)
        file.append(le32: 0x0605_4B50)
        file.append(le16: 0)
        file.append(le16: 0)
        file.append(le16: 1)
        file.append(le16: 1)
        file.append(le32: 0xFFFF_FFFF)
        file.append(le32: 0xFFFF_FFFF)
        file.append(le16: 0)
        return file
    }

    // MARK: - 3. The manifest

    func testTheManifestUsesTheSnapshotDataModelAndItsOwnVersion() throws {
        let package = try writeAPackage()
        let read = try PackageManifest.decode(json: package.manifest.jsonData())

        XCTAssertEqual(read.packageVersion, 1)
        // The package version is its own integer, per 15.5. A move
        // of the snapshot format version does not move it.
        var moved = read
        moved.streams[0].manifest.formatVersion += 1
        let reread = try PackageManifest.decode(json: moved.jsonData())
        XCTAssertEqual(reread.packageVersion, PackageManifest.currentVersion)
        XCTAssertEqual(
            reread.streams[0].manifest.formatVersion,
            read.streams[0].manifest.formatVersion + 1)
        XCTAssertEqual(read.exportedAt, stamp)
        XCTAssertEqual(read.sourceDevice, "iPad")

        let file = try XCTUnwrap(read.files.first)
        XCTAssertEqual(file.zipPath, "Documents/Games/Quest/Game/Save01.rvdata2")
        XCTAssertEqual(file.entry.path, "Game/Save01.rvdata2")
        XCTAssertEqual(file.entry.size, 4_096)
        XCTAssertEqual(file.entry.hash.count, 64)
        XCTAssertEqual(file.entry.compression, .stored)
        XCTAssertFalse(file.entry.partial)
    }

    // MARK: - 4. What each export holds

    func testAOneGameExportIsSparseAndALibraryExportHoldsTheSharedStreams() throws {
        let package = try writeAPackage()
        let paths = package.manifest.files.map(\.zipPath)
        XCTAssertEqual(paths, ["Documents/Games/Quest/Game/Save01.rvdata2"])
        XCTAssertFalse(paths.contains { $0.hasPrefix(PackageLayout.profilesPrefix) })
        XCTAssertFalse(paths.contains { $0 == PackageLayout.preferencesPath })

        var library = SnapshotManifest(mode: .slim, containerFolderName: "")
        library.entries = [
            entry(
                root: .preferences, path: PreferencesMemberPath.userDefaultsExport.path,
                bytes: Data("{}".utf8)),
            entry(
                root: .preferences,
                path: PreferencesMemberPath.profile(path: "pad.json").path,
                bytes: Data("{}".utf8)),
            entry(
                root: .preferences,
                path: PreferencesMemberPath.rescuedSavesBucket(
                    name: "Quest", path: "Save01.rvdata2"
                ).path,
                bytes: Data("s".utf8)),
        ]
        let shared = library.entries.compactMap { PackageLayout.zipPath(of: $0, in: library) }
        XCTAssertEqual(
            shared,
            [
                "Preferences/defaults.json",
                "Documents/Profiles/pad.json",
                "Documents/Rescued Saves/Quest/Save01.rvdata2",
            ])
    }

    // MARK: - 5. No game-scoped key in defaults.json

    func testTheDefaultsExportDropsEveryGameScopedKey() throws {
        let defaults: [String: JSONValue] = [
            "theme": .string("dark"),
            "hint.dismissed.controls": .bool(true),
            "controllerMap.global": .object(["a": .string("confirm")]),
            "controlsLayout.Quest": .object(["x": .int(1)]),
            "controlsLayout.6f2a": .object(["x": .int(2)]),
            "controllerMap.Quest": .object(["b": .string("cancel")]),
            "debugLogs": .bool(true),
            "disclaimerAcknowledgedVersion": .int(3),
            "somethingNobodyClassified": .int(1),
        ]
        let document = try PreferenceExport.decode(
            json: PreferenceExport.document(of: defaults, at: stamp))

        XCTAssertEqual(
            Set(document.values.keys),
            ["theme", "hint.dismissed.controls", "controllerMap.global"])
        for key in document.values.keys {
            XCTAssertFalse(PreferenceKeys.isGameScoped(key), key)
        }
        XCTAssertTrue(PreferenceKeys.isGameScoped("controlsLayout.Quest"))
        XCTAssertTrue(PreferenceKeys.isGameScoped("controllerMap.Quest"))
        XCTAssertFalse(PreferenceKeys.isGameScoped("controllerMap.global"))
    }

    // MARK: - 6. Every rejection, before any write

    func testEveryRejectionIsCaughtBeforeAWrite() throws {
        let bytes = Data(repeating: 1, count: 32)
        var manifest = SnapshotManifest(mode: .slim, containerFolderName: "Quest")
        manifest.entries = [entry(path: "Game/Save01.rvdata2", bytes: bytes)]
        let package = PackageManifest(
            exportedAt: stamp, sourceDevice: "iPad",
            streams: [PackageStream(key: manifest.gameKey, manifest: manifest)])
        let good = ZipEntry(
            path: "Documents/Games/Quest/Game/Save01.rvdata2",
            uncompressedSize: 32, compressedSize: 32, crc: 0, isDeflated: false,
            headerOffset: 0, isSymbolicLink: false)

        XCTAssertThrowsError(try PackageValidation.checkThePath("/etc/passwd")) {
            XCTAssertEqual($0 as? PackageRejection, .absolutePath("/etc/passwd"))
        }
        XCTAssertThrowsError(try PackageValidation.checkThePath("Documents/../../x")) {
            XCTAssertEqual($0 as? PackageRejection, .parentTraversal("Documents/../../x"))
        }

        var link = good
        link.path = "Documents/Games/Quest/Game/link"
        link.isSymbolicLink = true
        XCTAssertThrowsError(try PackageValidation.check(package, against: [good, link])) {
            XCTAssertEqual($0 as? PackageRejection, .link(link.path))
        }

        var stranger = good
        stranger.path = "Documents/Games/Quest/Game/extra.bin"
        XCTAssertThrowsError(try PackageValidation.check(package, against: [good, stranger])) {
            XCTAssertEqual($0 as? PackageRejection, .undeclaredFile(stranger.path))
        }

        XCTAssertThrowsError(try PackageValidation.check(package, against: [])) {
            XCTAssertEqual($0 as? PackageRejection, .missingFile(good.path))
        }

        var twice = package
        twice.streams[0].manifest.entries.append(twice.streams[0].manifest.entries[0])
        XCTAssertThrowsError(try PackageValidation.check(twice, against: [good])) {
            XCTAssertEqual($0 as? PackageRejection, .duplicatePath(good.path))
        }

        var short = good
        short.uncompressedSize = 31
        XCTAssertThrowsError(try PackageValidation.check(package, against: [short])) {
            XCTAssertEqual($0 as? PackageRejection, .wrongSize(good.path))
        }

        let file = try XCTUnwrap(package.files.first)
        XCTAssertThrowsError(
            try PackageValidation.checkTheContent(
                of: file, stagedSize: 32, stagedHash: String(repeating: "0", count: 64))
        ) {
            XCTAssertEqual($0 as? PackageRejection, .wrongHash(good.path))
        }
        XCTAssertNoThrow(
            try PackageValidation.checkTheContent(
                of: file, stagedSize: 32, stagedHash: file.entry.hash))
    }

    // MARK: - 7. A ZIP that is not a package

    func testAZipWithNoManifestFailsValidationWithAReason() throws {
        let url = root.appendingPathComponent("plain.zip")
        let writer = try ZipWriter(creating: url)
        try writer.add(data: Data("hello".utf8), at: "notes.txt")
        try writer.finish()

        XCTAssertThrowsError(try PackageSource(zip: url, packageId: "p1")) {
            XCTAssertEqual($0 as? PackageRejection, .noManifest)
            XCTAssertEqual(
                ($0 as? PackageRejection)?.line,
                "This ZIP file is not an Empo backup package.")
        }
        XCTAssertThrowsError(
            try PackageSource(zip: root.appendingPathComponent("nothing.zip"), packageId: "p1")
        ) {
            XCTAssertEqual($0 as? PackageRejection, .noManifest)
        }
    }

    // MARK: - 8. A newer Empo wrote it

    func testAFuturePackageVersionIsRejectedBeforeAnyWrite() throws {
        var package = try writeAPackage().manifest
        package.packageVersion = PackageManifest.currentVersion + 1

        let url = root.appendingPathComponent("future.zip")
        let writer = try ZipWriter(creating: url)
        try writer.add(data: package.jsonData(), at: PackageLayout.manifestPath)
        try writer.finish()

        XCTAssertThrowsError(try PackageSource(zip: url, packageId: "p1")) {
            XCTAssertEqual($0 as? PackageRejection, .futureVersion(2))
        }
    }

    // MARK: - 9. An interrupted import

    func testAnInterruptedImportLeavesOneRecordAndStoppingDeletesThePackage() {
        let record = RestoreResumeQuestion.record(
            targetId: PackageSource.targetId(packageId: "p1"),
            gameKey: BackupKeys.gameKey(containerFolderName: "Quest"),
            snapshotId: PackageSource.snapshotId(
                streamKey: BackupKeys.gameKey(containerFolderName: "Quest"), exportedAt: stamp),
            scope: .wholeGame,
            replacesTheTree: false,
            at: stamp)

        XCTAssertEqual(record.kind, .interruptedRestore)
        XCTAssertTrue(RestoreResumeQuestion.asks(record))
        // The record is what says the source was a package.
        XCTAssertEqual(PackageSource.packageId(ofTargetId: record.targetId), "p1")
        XCTAssertNil(PackageSource.packageId(ofTargetId: "dropbox-1"))

        // Deferring keeps the package and the staged files. Stopping
        // deletes both.
        let later = RestoreResumeQuestion.effect(of: .later)
        XCTAssertTrue(later.keepsRecord)
        XCTAssertFalse(later.deletesStagedBlobs)
        let stop = RestoreResumeQuestion.effect(of: .stop)
        XCTAssertFalse(stop.keepsRecord)
        XCTAssertTrue(stop.deletesStagedBlobs)
    }

    // MARK: - 10. Both doors while a game runs

    func testExportAndImportBothRefuseWhileAGameRuns() {
        XCTAssertFalse(PackageDoors.opens(gameIsPlaying: true))
        XCTAssertTrue(PackageDoors.opens(gameIsPlaying: false))
        XCTAssertEqual(
            PackageDoors.line(gameName: "Quest"),
            "Close Quest to export or import a backup.")
        XCTAssertNil(PackageDoors.line(gameName: nil))

        // The space check of 12.5 wants the source plus the floor of
        // 6.4.
        let floor = StagingBudget.freeSpaceFloorBytes
        XCTAssertNil(PackageDoors.shortfall(sourceBytes: 100, freeSpaceBytes: floor + 100))
        XCTAssertEqual(
            PackageDoors.shortfall(sourceBytes: 100, freeSpaceBytes: floor + 40), 60)
    }

    // MARK: - The import reads the package through the provider

    func testTheImportServesEachManifestAndBlobFromTheStagedPackage() async throws {
        let bytes = Data((0..<9_000).map { UInt8($0 % 97) })
        let package = try writeAPackage(files: [("Game/Save01.rvdata2", bytes)])
        let source = try PackageSource(zip: package.url, packageId: "p1")
        let stream = try XCTUnwrap(package.manifest.streams.first)

        let rows = PackageSource.rows(of: package.manifest, packageId: "p1")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].targetId, "package:p1")
        XCTAssertEqual(rows[0].deviceName, "iPad")
        XCTAssertEqual(rows[0].createdAt, stamp)
        XCTAssertEqual(rows[0].bytesToDownload, Int64(bytes.count))

        let paths = BackupNamespacePaths(root: "", namespaceId: "p1")
        let staged = root.appendingPathComponent("staged")
        try await source.get(
            path: paths.manifestPath(
                stream: BackupStream(key: stream.key), snapshotId: rows[0].snapshotId),
            localFile: staged)
        let read = try SnapshotManifest.decode(compressed: Data(contentsOf: staged))
        XCTAssertEqual(read, stream.manifest)

        let blob = root.appendingPathComponent("blob")
        try await source.get(
            path: paths.blobPath(
                hash: read.entries[0].hash, fanOutWidth: FormatDescriptor.version1FanOutWidth),
            localFile: blob)
        XCTAssertEqual(try Data(contentsOf: blob), bytes)

        do {
            try await source.get(path: paths.blobPath(hash: "ff", fanOutWidth: 2), localFile: blob)
            XCTFail("a hash the package does not hold answered")
        } catch {
            XCTAssertEqual(error, .notFound)
        }
        await source.close()
    }
}

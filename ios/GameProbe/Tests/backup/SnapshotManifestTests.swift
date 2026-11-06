import Foundation
import XCTest

@testable import GameProbe

final class SnapshotManifestTests: XCTestCase {

    private let containerName = "ゆめにっき Yume Nikki"

    // MARK: - Round trip

    func testTheFixtureManifestReadsWithExactFieldValues() throws {
        let manifest = try SnapshotManifest.decode(
            json: BackupFixtures.data("manifest-v1.json"))

        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.mode, .slim)
        XCTAssertEqual(manifest.containerFolderName, containerName)
        XCTAssertEqual(manifest.identityAlias, "Yume Nikki")
        XCTAssertEqual(manifest.sharedDataDirectory, "Data/kikiyama/yumenikki")
        XCTAssertEqual(manifest.rescuedSavesBuckets, ["Yume Nikki", "ゆめにっき"])

        XCTAssertEqual(manifest.versionMarker.gameINIHash, ContentHash.hex(ofUTF8: "Game.ini"))
        XCTAssertEqual(manifest.versionMarker.jgpManifestVersion, "2")
        XCTAssertEqual(manifest.versionMarker.fileCount, 1284)
        XCTAssertEqual(manifest.versionMarker.totalSize, 734_003_200)

        XCTAssertEqual(manifest.entries.count, 4)

        let save = manifest.entries[0]
        XCTAssertEqual(save.root, .container)
        XCTAssertEqual(save.path, "Game/Save01.rvdata2")
        XCTAssertEqual(save.size, 20480)
        XCTAssertEqual(save.modifiedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(save.hash, ContentHash.hex(ofUTF8: "Save01"))
        XCTAssertEqual(save.compression, .zlib)
        XCTAssertFalse(save.partial)
        XCTAssertEqual(save.detectionSource, .classifier)
        XCTAssertNil(save.chunks)

        let config = manifest.entries[1]
        XCTAssertEqual(config.root, .sharedData)
        XCTAssertEqual(config.path, "kikiyama/yumenikki/config.dat")
        XCTAssertEqual(config.size, 512)
        XCTAssertEqual(config.modifiedAt, Date(timeIntervalSince1970: 1_700_000_123))
        XCTAssertEqual(config.compression, .stored)
        XCTAssertTrue(config.partial)
        XCTAssertEqual(config.detectionSource, .runtimeWatch)
        XCTAssertEqual(
            config.chunks,
            [ContentHash.hex(ofUTF8: "chunk-a"), ContentHash.hex(ofUTF8: "chunk-b")])

        let rescued = manifest.entries[2]
        XCTAssertEqual(rescued.root, .rescuedSaves)
        XCTAssertEqual(rescued.path, "Yume Nikki/Save02.rvdata2")
        XCTAssertEqual(rescued.detectionSource, .manualMark)

        // A full-mode member carries no detection source.
        let art = manifest.entries[3]
        XCTAssertEqual(art.root, .container)
        XCTAssertEqual(art.path, "Game/Graphics/Titles/title.png")
        XCTAssertNil(art.detectionSource)
        XCTAssertNil(art.chunks)
    }

    /// The reserved chunk field survives a write and a read, so
    /// adding it later breaks nothing, per 15.2.
    func testTheManifestRoundTripsWithTheReservedFieldIncluded() throws {
        let manifest = try SnapshotManifest.decode(
            json: BackupFixtures.data("manifest-v1.json"))
        let back = try SnapshotManifest.decode(json: manifest.jsonData())

        XCTAssertEqual(back, manifest)
        XCTAssertEqual(back.entries[1].chunks?.count, 2)
    }

    func testAWrittenManifestOmitsTheReservedFieldItDoesNotUse() throws {
        let manifest = SnapshotManifest(
            mode: .full,
            containerFolderName: containerName,
            entries: [
                SnapshotManifest.Entry(
                    root: .container,
                    path: "Game/Game.ini",
                    size: 96,
                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    hash: ContentHash.hex(ofUTF8: "Game.ini"),
                    compression: .zlib)
            ])
        let text = String(decoding: try manifest.jsonData(), as: UTF8.self)

        XCTAssertFalse(text.contains("chunks"))
        XCTAssertFalse(text.contains("detectionSource"))
        XCTAssertEqual(try SnapshotManifest.decode(json: manifest.jsonData()), manifest)
    }

    func testAManifestKeepsTheGameTitle() throws {
        let manifest = SnapshotManifest(
            mode: .slim, containerFolderName: containerName, title: "Pokémon Emerald")
        XCTAssertEqual(
            try SnapshotManifest.decode(json: manifest.jsonData()).title, "Pokémon Emerald")
        XCTAssertNil(
            try SnapshotManifest.decode(json: BackupFixtures.data("manifest-v1.json")).title)
    }

    func testTheGameKeyComesFromTheExactContainerName() throws {
        let manifest = try SnapshotManifest.decode(
            json: BackupFixtures.data("manifest-v1.json"))
        XCTAssertEqual(
            manifest.gameKey, BackupKeys.gameKey(containerFolderName: containerName))
    }

    // MARK: - The compressed manifest of 5.6

    func testACompressedManifestRoundTrips() throws {
        let manifest = try SnapshotManifest.decode(
            json: BackupFixtures.data("manifest-v1.json"))
        let compressed = try manifest.compressedData()

        XCTAssertLessThan(compressed.count, try manifest.jsonData().count)
        XCTAssertEqual(try SnapshotManifest.decode(compressed: compressed), manifest)
    }

    func testACompressedManifestThatInflatesPastTheLimitIsRefused() throws {
        let manifest = try SnapshotManifest.decode(
            json: BackupFixtures.data("manifest-v1.json"))
        let compressed = try manifest.compressedData()
        let size = try manifest.jsonData().count

        XCTAssertThrowsError(
            try SnapshotManifest.decode(compressed: compressed, maxBytes: size - 1)
        ) { error in
            XCTAssertEqual(error as? BlobCodec.Failure, .tooLarge)
        }
        XCTAssertEqual(
            try SnapshotManifest.decode(compressed: compressed, maxBytes: size), manifest)
        XCTAssertEqual(SnapshotManifest.inflatedSizeLimit, 256 * 1_024 * 1_024)
    }

    // MARK: - Rejections

    /// An entry this reader cannot store or restore stops the read,
    /// and the report names the path.
    func testAnUnknownCompressionAlgorithmIsRejectedAndNamesThePath() throws {
        let data = try BackupFixtures.data("manifest-unknown-compression.json")

        XCTAssertThrowsError(try SnapshotManifest.decode(json: data)) { error in
            XCTAssertEqual(
                error as? ManifestFailure,
                .unknownCompression(
                    algorithm: "zstd", path: "kikiyama/yumenikki/config.dat"))
        }
    }

    func testAnUnknownRootIsRejectedAndNamesThePath() throws {
        var text = String(
            decoding: try BackupFixtures.data("manifest-v1.json"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"shared-data\"", with: "\"pack-file\"")

        XCTAssertThrowsError(try SnapshotManifest.decode(json: Data(text.utf8))) { error in
            XCTAssertEqual(
                error as? ManifestFailure,
                .unknownRoot(label: "pack-file", path: "kikiyama/yumenikki/config.dat"))
        }
    }

    func testAnUnknownDetectionSourceIsRejectedAndNamesThePath() throws {
        var text = String(
            decoding: try BackupFixtures.data("manifest-v1.json"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"runtime-watch\"", with: "\"guesswork\"")

        XCTAssertThrowsError(try SnapshotManifest.decode(json: Data(text.utf8))) { error in
            XCTAssertEqual(
                error as? ManifestFailure,
                .unknownDetectionSource(
                    label: "guesswork", path: "kikiyama/yumenikki/config.dat"))
        }
    }

    func testAHashThatIsNotAContentHashIsRejected() throws {
        var text = String(
            decoding: try BackupFixtures.data("manifest-v1.json"), as: UTF8.self)
        text = text.replacingOccurrences(
            of: "938f7934f3328f54e648bd5812473be574ace4c4501e2e0c1a81e67fca77e2f8",
            with: "../../../Documents/Save01.rvdata2")

        XCTAssertThrowsError(try SnapshotManifest.decode(json: Data(text.utf8))) { error in
            guard case .badHash = error as? ManifestFailure else {
                return XCTFail("expected a bad hash failure, got \(error)")
            }
        }
    }

    // MARK: - The read-only test of 5.16

    func testAVersion2ManifestIsReadOnlyAndRefusesAWriteAndAPrune() throws {
        let manifest = try SnapshotManifest.decode(
            json: BackupFixtures.data("manifest-v2.json"))

        XCTAssertEqual(manifest.formatVersion, 2)
        XCTAssertEqual(manifest.access, .readOnly(.newerFormatVersion(2)))
        XCTAssertFalse(manifest.access.allowsWrite)
        XCTAssertFalse(manifest.access.allowsPrune)
        // It still lists what it can parse.
        XCTAssertEqual(manifest.entries.count, 4)
    }

    func testAVersion1ManifestWritesAndPrunes() throws {
        let manifest = try SnapshotManifest.decode(
            json: BackupFixtures.data("manifest-v1.json"))

        XCTAssertEqual(manifest.access, .readWrite)
        XCTAssertTrue(manifest.access.allowsWrite)
        XCTAssertTrue(manifest.access.allowsPrune)
    }
}

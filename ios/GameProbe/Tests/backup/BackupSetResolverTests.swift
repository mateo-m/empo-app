import Foundation
import XCTest

@testable import GameProbe

/// The backup set of SPEC 3.1 to 3.4, over the fixture tree in
/// `Tests/Fixtures/backup/container/`.
final class BackupSetResolverTests: XCTestCase {

    private var container: URL { BackupFixtures.url("container") }
    private var sharedData: URL { BackupFixtures.url("shared-data") }

    private func resolve(
        mode: BackupMode, marks: [String] = [], watched: [String] = []
    ) -> GameBackupSet {
        BackupSetResolver.resolve(
            GameBackupSetRequest(
                containerURL: container,
                mode: mode,
                manualMarks: marks,
                runtimeWatchPaths: watched))
    }

    private func paths(_ set: GameBackupSet, under root: EntryRoot = .container) -> [String] {
        set.members(under: root).map(\.path)
    }

    // MARK: - Full mode against slim mode, per 3.3 and 3.4

    func testFullModeListsEveryFileOfTheTree() {
        let paths = paths(resolve(mode: .full))

        XCTAssertEqual(
            paths,
            [
                "EmpoState/backup.json",
                "EmpoState/game_settings.json",
                "Game/Data/Scripts.rxdata",
                "Game/Game.ini",
                "Game/Game.rxdata",
                "Game/Graphics/title.png",
                "Game/Save Data/slot1.bin",
                "Game/autosave.sav",
                "Game/patch.exe",
                "Game/save1.dat",
                "Metadata/metadata.json",
            ])
    }

    func testSlimModeListsTheClassifierMatchesAndTheAlwaysInList() {
        let paths = paths(resolve(mode: .slim))

        XCTAssertEqual(
            paths,
            [
                "EmpoState/backup.json",
                "EmpoState/game_settings.json",
                "Game/Game.rxdata",
                "Game/Save Data/slot1.bin",
                "Game/autosave.sav",
                "Game/save1.dat",
                "Metadata/metadata.json",
            ])
    }

    func testTheAlwaysInFilesCarryNoDetectionSource() {
        let set = resolve(mode: .slim)
        let stateEntry = set.members.first { $0.path == "EmpoState/backup.json" }

        XCTAssertNotNil(stateEntry)
        XCTAssertNil(stateEntry?.detectionSource)
    }

    func testAClassifierMatchCarriesTheClassifierLabel() {
        let set = resolve(mode: .slim)
        let save = set.members.first { $0.path == "Game/Game.rxdata" }

        XCTAssertEqual(save?.detectionSource, .classifier)
    }

    func testAFullModeTreeStillLabelsWhatASourceFound() {
        // 7.2 tells a partial save from a partial log by the label,
        // so a full-mode entry keeps the label its source gave it.
        let set = resolve(mode: .full)

        XCTAssertEqual(
            set.members.first { $0.path == "Game/Game.rxdata" }?.detectionSource, .classifier)
        XCTAssertNil(set.members.first { $0.path == "Game/patch.exe" }?.detectionSource)
    }

    // MARK: - Always out, per 3.2

    func testFontsStayOutOfBothModes() {
        for mode in BackupMode.allCases {
            XCTAssertFalse(
                paths(resolve(mode: mode)).contains("Game/Fonts/pixel.ttf"),
                "Fonts joined the \(mode.rawValue) set")
        }
    }

    func testArtworkStaysOutAndMetadataJSONStaysIn() {
        for mode in BackupMode.allCases {
            let paths = paths(resolve(mode: mode))
            XCTAssertFalse(paths.contains("Metadata/artwork.jpg"))
            XCTAssertTrue(paths.contains("Metadata/metadata.json"))
        }
    }

    func testLogsStayOutOfBothModes() {
        for mode in BackupMode.allCases {
            XCTAssertFalse(paths(resolve(mode: mode)).contains("Logs/session-history.log"))
        }
    }

    func testADisplacedCopyStaysOutOfBothModes() {
        // The file carries the Marshal magic, so the classifier
        // would take it. Only the marker rule keeps it out, and
        // without that rule every restore doubles the save payload.
        XCTAssertTrue(
            PortableGameSaves.hasMarshalMagic(
                container.appendingPathComponent("Game/Game.rxdata.empo-displaced.bak")))

        for mode in BackupMode.allCases {
            XCTAssertFalse(
                paths(resolve(mode: mode)).contains("Game/Game.rxdata.empo-displaced.bak"))
        }
    }

    func testAReplacedTreeStaysOutOfBothModes() {
        for mode in BackupMode.allCases {
            let paths = paths(resolve(mode: mode))
            XCTAssertFalse(paths.contains("Game.empo-displaced/Game.ini"))
            XCTAssertFalse(paths.contains("Game.empo-displaced/Game.rxdata"))
        }
    }

    func testTheMarkerMatchesEveryFormARestoreWrites() {
        XCTAssertTrue(BackupSetRules.carriesDisplacedMarker("Game.rxdata.empo-displaced.bak"))
        XCTAssertTrue(BackupSetRules.carriesDisplacedMarker("Game.rxdata.empo-displaced-2.bak"))
        XCTAssertTrue(BackupSetRules.carriesDisplacedMarker("Default.empo-displaced"))
        XCTAssertFalse(BackupSetRules.carriesDisplacedMarker("Game.rxdata"))
        // The path-regression marker of the UserData drain is a
        // different marker and stays in the set.
        XCTAssertFalse(
            BackupSetRules.carriesDisplacedMarker("Game.rxdata.empo-path-regression.bak"))
    }

    func testAlwaysOutBeatsAMark() {
        // Marks are additive against the classifier, per 3.6. They
        // do not bring back what 3.2 removed.
        let paths = paths(resolve(mode: .slim, marks: ["Logs", "Metadata/artwork.jpg"]))

        XCTAssertFalse(paths.contains("Logs/session-history.log"))
        XCTAssertFalse(paths.contains("Metadata/artwork.jpg"))
    }

    // MARK: - Marks, per 3.6

    func testAMarkInsideADirectoryTheClassifierSkipsEntersTheSet() {
        // `Data/` is an engine directory, so `PortableGameSaves`
        // never enters it, Marshal magic and all.
        XCTAssertFalse(paths(resolve(mode: .slim)).contains("Game/Data/Scripts.rxdata"))

        let set = resolve(mode: .slim, marks: ["Game/Data"])
        let marked = set.members.first { $0.path == "Game/Data/Scripts.rxdata" }

        XCTAssertNotNil(marked)
        XCTAssertEqual(marked?.detectionSource, .manualMark)
    }

    func testAMarkOnOneFileTakesThatFileAlone() {
        let set = resolve(mode: .slim, marks: ["Game/patch.exe"])
        let paths = paths(set)

        XCTAssertTrue(paths.contains("Game/patch.exe"))
        XCTAssertFalse(paths.contains("Game/Graphics/title.png"))
    }

    func testAMarkWinsTheLabelOverTheClassifier() {
        let set = resolve(mode: .slim, marks: ["Game/Game.rxdata"])

        XCTAssertEqual(
            set.members.first { $0.path == "Game/Game.rxdata" }?.detectionSource, .manualMark)
    }

    func testAPartialNameIsNoMark() {
        XCTAssertFalse(BackupSetRules.mark("Game/Dat", covers: "Game/Data/Scripts.rxdata"))
        XCTAssertTrue(BackupSetRules.mark("Game/Data", covers: "Game/Data/Scripts.rxdata"))
    }

    // MARK: - The runtime watch label, per 3.6

    func testAWatchedWriteJoinsTheSlimModeSet() {
        let set = resolve(mode: .slim, watched: ["Game/Graphics/title.png"])
        let joined = set.members.first { $0.path == "Game/Graphics/title.png" }

        XCTAssertNotNil(joined)
        XCTAssertEqual(joined?.detectionSource, .runtimeWatch)
    }

    // MARK: - The members outside the container, per 4.5

    func testASharedDataDirectoryTwoGamesNameResolvesForBoth() {
        func set(forContainer url: URL) -> GameBackupSet {
            BackupSetResolver.resolve(
                GameBackupSetRequest(
                    containerURL: url, mode: .slim, sharedDataDirectory: sharedData))
        }

        let first = set(forContainer: container)
        let second = set(forContainer: container)

        // Both games record the same directory and the same paths,
        // so the content-addressed store of 5.4 uploads it once.
        XCTAssertEqual(first.sharedDataDirectory, sharedData.path)
        XCTAssertEqual(second.sharedDataDirectory, sharedData.path)
        XCTAssertEqual(
            paths(first, under: .sharedData), ["Game.rxdata", "config.ini"])
        XCTAssertEqual(
            paths(first, under: .sharedData), paths(second, under: .sharedData))
    }

    func testARescuedSavesBucketThatMatchesAGameRidesThatGamesStream() {
        let bucket = BackupFixtures.url("rescued").appendingPathComponent("Fixture Quest")
        let set = BackupSetResolver.resolve(
            GameBackupSetRequest(
                containerURL: container,
                mode: .slim,
                rescuedSavesBuckets: ["Fixture Quest": bucket]))

        XCTAssertEqual(set.rescuedSavesBuckets, ["Fixture Quest"])
        XCTAssertEqual(
            paths(set, under: .rescuedSaves),
            ["Fixture Quest/.empo-origin.json", "Fixture Quest/Save1.rxdata"])
    }

    func testABucketThatMatchesNothingRidesTheStreamWithNoGame() {
        let bucket = BackupFixtures.url("rescued").appendingPathComponent("Long Gone")
        let set = BackupSetResolver.resolveLibraryStream(
            LibraryBackupSetRequest(rescuedSavesBuckets: ["Long Gone": bucket]))

        XCTAssertEqual(
            paths(set, under: .preferences),
            ["rescued-saves/Long Gone/.empo-origin.json", "rescued-saves/Long Gone/Save1.rxdata"])
    }

    // MARK: - The stream that belongs to no game, per 5.3

    func testTheLayoutProfilesRideTheStreamWithNoGame() {
        let set = BackupSetResolver.resolveLibraryStream(
            LibraryBackupSetRequest(profilesDirectory: BackupFixtures.url("profiles")))

        XCTAssertEqual(
            paths(set, under: .preferences),
            ["profiles/Default/layout.json", "profiles/Landscape/layout.json"])
    }

    func testTheUserDefaultsExportRidesTheStreamWithNoGame() {
        let export = BackupFixtures.url("container")
            .appendingPathComponent("Metadata/metadata.json")
        let set = BackupSetResolver.resolveLibraryStream(
            LibraryBackupSetRequest(userDefaultsExportFile: export))

        XCTAssertEqual(paths(set, under: .preferences), ["userdefaults.json"])
    }

    func testAMissingRootResolvesToAnEmptySet() {
        let missing = container.appendingPathComponent("no-such-game")
        let set = BackupSetResolver.resolve(
            GameBackupSetRequest(containerURL: missing, mode: .full))

        XCTAssertTrue(set.members.isEmpty)
    }

    // MARK: - The size of the set

    func testTheTotalSizeAddsEveryMember() {
        let set = resolve(mode: .slim)
        let byHand = set.members.reduce(Int64(0)) { $0 + $1.size }

        XCTAssertEqual(set.totalSize, byHand)
        XCTAssertGreaterThan(set.totalSize, 0)
    }
}

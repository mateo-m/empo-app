import Foundation
import XCTest

@testable import GameProbe

/// The three doors of SPEC 11.3, the rows of 11.6, the fresh-install
/// merge of 11.4, the adopt of 11.5, the attach of 11.11, and the
/// edges of 11.14.
///
/// Rows 5 and 6 of the table in 11.2 are here, because both are
/// fresh-install rules.
final class RestorePickerTests: XCTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshotId(_ offset: TimeInterval) -> String {
        BackupKeys.snapshotId(date: stamp.addingTimeInterval(offset), suffix: "abcdef")
    }

    private func row(
        _ offset: TimeInterval,
        device: String = "iPhone",
        namespace: String = "ns-1",
        folderName: String = "Quest",
        alias: String? = nil,
        formatVersion: Int = FormatDescriptor.currentVersion
    ) -> SnapshotRow {
        let id = snapshotId(offset)
        return SnapshotRow(
            targetId: "target-1", targetLabel: "Homelab", namespaceId: namespace,
            deviceName: device, snapshotId: id,
            createdAt: BackupKeys.timestamp(ofSnapshotId: id) ?? stamp,
            mode: .slim, bytesToDownload: 10, hasPartialPaths: false,
            versionMarkerDiffers: false,
            identity: SnapshotIdentity(containerFolderName: folderName, identityAlias: alias),
            formatVersion: formatVersion)
    }

    // MARK: - The rows, per 11.6

    func testARowIsBuiltFromTheManifestHeader() {
        let id = snapshotId(0)
        let manifest = SnapshotManifest(
            mode: .full,
            containerFolderName: "Quest",
            identityAlias: "Quest Demo",
            versionMarker: SnapshotManifest.VersionMarker(fileCount: 4),
            entries: [
                SnapshotManifest.Entry(
                    root: .container, path: "a", size: 30, modifiedAt: stamp, hash: "aa",
                    compression: .zlib, partial: true)
            ])

        let row = SnapshotRow(
            manifest: manifest, targetId: "target-1", targetLabel: "Homelab",
            namespaceId: "ns-1", deviceName: "Old iPad", snapshotId: id,
            localVersionMarker: SnapshotManifest.VersionMarker(fileCount: 9))

        XCTAssertEqual(row.mode, .full)
        XCTAssertEqual(row.bytesToDownload, 30)
        XCTAssertTrue(row.hasPartialPaths)
        XCTAssertTrue(row.versionMarkerDiffers)
        XCTAssertEqual(row.identity.names, ["Quest", "Quest Demo"])
        XCTAssertEqual(row.createdAt, BackupKeys.timestamp(ofSnapshotId: id))
    }

    func testTheRowsGroupUnderDayHeadersNewestFirst() {
        let today = row(0)
        let alsoToday = row(60 * 60)
        let yesterday = row(-60 * 60 * 30)

        // A fixed calendar, so the day boundary does not move with the
        // time zone of the machine that runs the test.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        let days = RestorePicker.days([yesterday, today, alsoToday], calendar: utc)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].rows.map(\.snapshotId), [alsoToday.snapshotId, today.snapshotId])
        XCTAssertEqual(days[1].rows.map(\.snapshotId), [yesterday.snapshotId])
    }

    // MARK: - The manual door, per 11.3

    func testTheManualDoorListsOneGameAcrossEveryTargetAndNamespace() {
        let rows = [
            row(0, device: "iPhone", namespace: "ns-1"),
            row(-100, device: "iPad", namespace: "ns-2"),
            row(-200, folderName: "Other Game"),
        ]

        let listed = RestorePicker.rows(rows, of: GameIdentity(folderName: "Quest"))
        XCTAssertEqual(listed.map(\.deviceName), ["iPhone", "iPad"])
    }

    func testTheManualDoorMatchesThroughAnAlias() {
        let rows = [row(0, folderName: "Quest Demo")]
        let game = GameIdentity(folderName: "Quest", aliases: ["Quest Demo"])

        XCTAssertEqual(RestorePicker.rows(rows, of: game).count, 1)
    }

    // MARK: - The namespace list, per 11.3 and 11.11

    func testSnapshotsThatMatchNoGameSitInTheTrailingSection() {
        let rows = [row(0, folderName: "Quest"), row(-100, folderName: "Nothing Installed")]
        let sections = RestorePicker.sections(rows, among: [GameIdentity(folderName: "Quest")])

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].game?.folderName, "Quest")
        XCTAssertNil(sections.last?.game)
        XCTAssertEqual(sections.last?.rows.first?.identity.containerFolderName, "Nothing Installed")
        XCTAssertEqual(RestorePicker.otherSnapshotsHeading, "Other snapshots")
    }

    func testATargetWithNothingOnItHasNoSections() {
        XCTAssertTrue(RestorePicker.sections([], among: []).isEmpty)
        XCTAssertEqual(RestoreNotices.emptyTargetLine, "No backups on this target yet")
    }

    // MARK: - The fresh-install merge, per 11.4 and row 5 of 11.2

    /// Row 5: several namespaces hold one game. They merge, and each
    /// game defaults to its newest snapshot across all of them.
    func testThreeNamespacesHoldingOneGameMergeToOneRow() {
        let plan = FreshInstallMerge.plan(gameRows: [
            row(-200, device: "Old iPhone", namespace: "ns-1"),
            row(0, device: "New iPad", namespace: "ns-2"),
            row(-100, device: "Old iPad", namespace: "ns-3"),
        ])

        XCTAssertEqual(plan.games.count, 1)
        let game = plan.games[0]
        XCTAssertEqual(game.snapshots.count, 3)
        XCTAssertEqual(game.selectedSnapshotId, snapshotId(0))
        XCTAssertEqual(game.sourceDeviceName, "New iPad")
        XCTAssertEqual(
            game.snapshots.map(\.deviceName), ["New iPad", "Old iPad", "Old iPhone"])
        XCTAssertTrue(game.isSelected)
    }

    func testTwoGamesEachKeepTheirOwnRow() {
        let plan = FreshInstallMerge.plan(gameRows: [
            row(0, folderName: "Quest"), row(-100, folderName: "Adventure"),
        ])

        XCTAssertEqual(plan.games.map(\.name), ["Adventure", "Quest"])
    }

    func testThePreferencesAndRescuedSavesRowsArePreselected() {
        let plan = FreshInstallMerge.plan(
            gameRows: [row(0)],
            preferencesRow: row(0),
            orphanedBuckets: ["Old Quest", "Another"])

        XCTAssertEqual(plan.preferences?.kind, .preferences)
        XCTAssertTrue(plan.preferences?.isSelected == true)
        XCTAssertEqual(plan.rescuedSaves?.bucketNames, ["Another", "Old Quest"])
        XCTAssertTrue(plan.rescuedSaves?.isSelected == true)
    }

    func testTheDoorOpensOnlyForAnEmptyLibraryAndAFirstTarget() {
        XCTAssertTrue(
            FreshInstallMerge.opens(
                libraryIsEmpty: true, isFirstTarget: true, foundNamespaces: true))
        XCTAssertFalse(
            FreshInstallMerge.opens(
                libraryIsEmpty: false, isFirstTarget: true, foundNamespaces: true))
        XCTAssertFalse(
            FreshInstallMerge.opens(
                libraryIsEmpty: true, isFirstTarget: false, foundNamespaces: true))
        XCTAssertFalse(
            FreshInstallMerge.opens(
                libraryIsEmpty: true, isFirstTarget: true, foundNamespaces: false))
    }

    // MARK: - The hints, per 11.4

    func testAHintNamesTheServiceAndNeverTheAccount() {
        let dropbox = TargetDescriptor(
            id: "t-1", provider: .dropbox, label: "Dropbox", accountHint: nil, root: "/Apps/Empo")

        XCTAssertEqual(
            FreshInstallHints.line(for: dropbox),
            "This library is also backed up to Dropbox. Add Dropbox to see those backups too.")
    }

    func testASelfHostedHintNamesTheLabelAndTheRoot() {
        let server = TargetDescriptor(
            id: "t-2", provider: .webdav, label: "Homelab", root: "empo-backups")

        XCTAssertEqual(
            FreshInstallHints.line(for: server),
            "This library is also backed up to Homelab. Add it and point it at empo-backups to "
                + "see those backups too.")
    }

    func testAnICloudEntryThisBuildCannotOpenSaysSo() {
        let iCloud = TargetDescriptor(id: "t-3", provider: .iCloudDrive, label: "iCloud", root: "")

        XCTAssertEqual(
            FreshInstallHints.line(for: iCloud, canOpenICloud: false),
            FreshInstallHints.iCloudUnavailableLine)
        XCTAssertTrue(FreshInstallHints.iCloudUnavailableLine.contains("App Store"))
        XCTAssertNotEqual(
            FreshInstallHints.line(for: iCloud, canOpenICloud: true),
            FreshInstallHints.iCloudUnavailableLine)
    }

    func testAHintNeverNamesATargetThisInstallAlreadyHas() {
        let one = TargetDescriptor(id: "t-1", provider: .dropbox, label: "Dropbox", root: "")
        let two = TargetDescriptor(id: "t-2", provider: .webdav, label: "Homelab", root: "")

        XCTAssertEqual(
            FreshInstallHints.lines(streamed: [one, two], configuredTargetIds: ["t-1"]).count, 1)
    }

    // MARK: - Adopt, per 11.5 and row 6 of 11.2

    /// Row 6: a fresh install on a device that matches a namespace's
    /// recorded device is offered that namespace's history.
    func testAdoptFiresOnlyForANamespaceThisDeviceWrote() {
        let mine = DeviceRecord(
            deviceId: "device-1", model: "iPhone", name: "My iPhone", lastWriteAt: stamp)
        let theirs = DeviceRecord(
            deviceId: "device-2", model: "iPad", name: "Old iPad", lastWriteAt: stamp)

        XCTAssertEqual(
            AdoptQuestion.namespaces(
                records: ["ns-1": mine, "ns-2": theirs], thisDeviceId: "device-1"),
            ["ns-1"])
    }

    func testAGenuinelyNewDeviceSeesNoAdoptQuestion() {
        let theirs = DeviceRecord(
            deviceId: "device-2", model: "iPad", name: "Old iPad", lastWriteAt: stamp)

        XCTAssertTrue(
            AdoptQuestion.namespaces(records: ["ns-2": theirs], thisDeviceId: "device-9").isEmpty)
    }

    func testANamespaceThisDeviceAlreadyOwnsAsksNothing() {
        XCTAssertFalse(
            AdoptQuestion.fires(
                recordedDeviceId: "device-1", thisDeviceId: "device-1", alreadyOwned: true))
        XCTAssertEqual(AdoptQuestion.defaultAnswer, .adopt)
    }

    /// A device that adopts leaves no empty namespace behind,
    /// because a namespace id is created only at the first write.
    /// Nothing in the adopt path makes one.
    func testAdoptingMakesNoNamespace() {
        let mine = DeviceRecord(
            deviceId: "device-1", model: "iPhone", name: "My iPhone", lastWriteAt: stamp)
        let found = AdoptQuestion.namespaces(records: ["ns-1": mine], thisDeviceId: "device-1")

        XCTAssertEqual(found, ["ns-1"])
        XCTAssertEqual(found.count, 1)
    }

    // MARK: - The attach, per 11.11

    func testAnAttachWritesTheAliasAndTheNextRestoreMatches() {
        let snapshot = SnapshotIdentity(containerFolderName: "Quest Demo")
        let game = GameIdentity(folderName: "Quest")

        guard
            let store = AttachAction.record(
                snapshot: snapshot, into: game, aliases: IdentityAliases())
        else { return XCTFail("the attach has to record an alias") }

        XCTAssertEqual(store.aliases, ["Quest Demo"])
        let attached = store.identity(forFolderName: "Quest")
        XCTAssertTrue(GameIdentityMatch.matches(snapshot, attached))
        XCTAssertEqual(RestorePicker.rows([row(0, folderName: "Quest Demo")], of: attached).count, 1)
    }

    func testASecondAttachOfTheSameSnapshotAsksNothing() {
        let snapshot = SnapshotIdentity(containerFolderName: "Quest Demo")
        let game = GameIdentity(folderName: "Quest", aliases: ["Quest Demo"])

        XCTAssertNil(
            AttachAction.record(
                snapshot: snapshot, into: game,
                aliases: IdentityAliases(aliases: ["Quest Demo"])))
    }

    func testTheAttachCopyNamesTheTargetGame() {
        XCTAssertEqual(AttachAction.actionLabel, "Restore into a different game…")
        XCTAssertEqual(AttachAction.confirmTitle(targetGameName: "Quest"), "Restore into Quest?")
        XCTAssertTrue(AttachAction.confirmBody(targetGameName: "Quest").contains("Quest"))
        XCTAssertEqual(AttachAction.pickTitle, "Restore into a different game")
        XCTAssertTrue(AttachAction.actionLabel.hasPrefix(AttachAction.pickTitle))
        XCTAssertTrue(AttachAction.pickBody(snapshotName: "Quest Demo").contains("Quest Demo"))
    }

    /// The attach names a game after the row was built, so the
    /// question of 11.10 needs the snapshot's own marker.
    func testARowCarriesTheMarkerOfItsSnapshot() {
        let marker = SnapshotManifest.VersionMarker(fileCount: 3, totalSize: 900)
        let manifest = SnapshotManifest(
            mode: .full, containerFolderName: "Quest Demo", versionMarker: marker)
        let built = SnapshotRow(
            manifest: manifest, targetId: "target-1", targetLabel: "Homelab",
            namespaceId: "ns-1", deviceName: "iPhone", snapshotId: snapshotId(0))

        XCTAssertEqual(built.versionMarker, marker)
        XCTAssertFalse(built.versionMarkerDiffers, "this device holds no tree for the game")
        XCTAssertTrue(
            VersionMarkerSheet.shows(
                mode: built.mode, scope: .wholeGame,
                snapshot: built.versionMarker, local: SnapshotManifest.VersionMarker()))
    }

    // MARK: - The edges, per 11.14

    func testANamespaceFromANewerEmpoStaysRestorableAndRefusesEveryWrite() {
        let newer = row(0, formatVersion: FormatDescriptor.currentVersion + 1)

        XCTAssertFalse(newer.access.allowsWrite)
        XCTAssertFalse(newer.access.allowsPrune)
        XCTAssertTrue(RestoreNotices.showsNewerEmpoLine(newer.access))
        XCTAssertEqual(
            RestorePicker.rows([newer], of: GameIdentity(folderName: "Quest")).count, 1)
    }

    func testANamespaceThisEmpoWroteCarriesNoUpdateLine() {
        XCTAssertFalse(RestoreNotices.showsNewerEmpoLine(row(0).access))
    }
}

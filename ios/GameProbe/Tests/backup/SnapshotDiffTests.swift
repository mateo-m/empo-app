import Foundation
import XCTest

@testable import GameProbe

/// What earns a snapshot, per SPEC 7.7. Content decides, and there
/// is no clock debounce.
final class SnapshotDiffTests: XCTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func member(
        _ path: String, size: Int64 = 10, at date: Date? = nil,
        source: DetectionSource? = nil
    ) -> BackupSetMember {
        BackupSetMember(
            root: .container, path: path, size: size,
            modifiedAt: date ?? stamp, detectionSource: source)
    }

    private func entry(
        _ path: String, size: Int64 = 10, at date: Date? = nil, hash: String = "aa",
        partial: Bool = false, source: DetectionSource? = nil
    ) -> SnapshotManifest.Entry {
        SnapshotManifest.Entry(
            root: .container, path: path, size: size, modifiedAt: date ?? stamp,
            hash: hash, compression: .zlib, partial: partial, detectionSource: source)
    }

    private func manifest(_ entries: [SnapshotManifest.Entry]) -> SnapshotManifest {
        SnapshotManifest(mode: .slim, containerFolderName: "Quest", entries: entries)
    }

    // MARK: - The filter

    func testTheFirstRunHashesEveryMember() {
        let plan = SnapshotDiff.plan(
            members: [member("save1.dat"), member("save2.dat")], previous: nil)

        XCTAssertEqual(plan.changed.map(\.path), ["save1.dat", "save2.dat"])
        XCTAssertTrue(plan.reused.isEmpty)
    }

    func testAMatchOnSizeAndModifiedTimeIsReused() {
        let plan = SnapshotDiff.plan(
            members: [member("save1.dat")], previous: manifest([entry("save1.dat")]))

        XCTAssertTrue(plan.changed.isEmpty)
        XCTAssertEqual(plan.reused.map(\.hash), ["aa"])
    }

    func testASizeChangeHashesAgain() {
        let plan = SnapshotDiff.plan(
            members: [member("save1.dat", size: 11)],
            previous: manifest([entry("save1.dat", size: 10)]))

        XCTAssertEqual(plan.changed.map(\.path), ["save1.dat"])
    }

    func testAModifiedTimeChangeHashesAgain() {
        let plan = SnapshotDiff.plan(
            members: [member("save1.dat", at: stamp.addingTimeInterval(5))],
            previous: manifest([entry("save1.dat")]))

        XCTAssertEqual(plan.changed.map(\.path), ["save1.dat"])
    }

    func testAPartialPathAlwaysHashesAgain() {
        let plan = SnapshotDiff.plan(
            members: [member("save1.dat")],
            previous: manifest([entry("save1.dat", partial: true)]))

        XCTAssertEqual(plan.changed.map(\.path), ["save1.dat"])
        XCTAssertTrue(plan.reused.isEmpty)
    }

    func testTheFilterComparesModifiedTimesAtTheManifestPrecision() {
        // The manifest carries milliseconds and the filesystem
        // reports nanoseconds. A finer comparison would call every
        // file changed on every run.
        let finer = stamp.addingTimeInterval(0.000_04)
        let plan = SnapshotDiff.plan(
            members: [member("save1.dat", at: finer)],
            previous: manifest([entry("save1.dat", at: stamp)]))

        XCTAssertEqual(plan.reused.count, 1)
        XCTAssertTrue(plan.changed.isEmpty)
    }

    func testAWholeMillisecondStillCountsAsAChange() {
        let plan = SnapshotDiff.plan(
            members: [member("save1.dat", at: stamp.addingTimeInterval(0.002))],
            previous: manifest([entry("save1.dat", at: stamp)]))

        XCTAssertEqual(plan.changed.map(\.path), ["save1.dat"])
    }

    func testAReusedEntryTakesThisRunsDetectionSource() {
        let plan = SnapshotDiff.plan(
            members: [member("save1.dat", source: .runtimeWatch)],
            previous: manifest([entry("save1.dat", source: .classifier)]))

        XCTAssertEqual(plan.reused.first?.detectionSource, .runtimeWatch)
    }

    // MARK: - What earns a snapshot

    func testAModifiedTimeTouchWithTheSameBytesEarnsNothing() {
        // The entry set carries the same hashes, so no snapshot is
        // written even though the mtime moved.
        let previous = manifest([entry("save1.dat", hash: "aa")])
        let entries = [entry("save1.dat", at: stamp.addingTimeInterval(90), hash: "aa")]

        XCTAssertFalse(SnapshotDiff.earnsSnapshot(entries: entries, previous: previous))
    }

    func testANewHashEarnsASnapshot() {
        XCTAssertTrue(
            SnapshotDiff.earnsSnapshot(
                entries: [entry("save1.dat", hash: "bb")],
                previous: manifest([entry("save1.dat", hash: "aa")])))
    }

    func testAPathThatArrivedEarnsASnapshot() {
        XCTAssertTrue(
            SnapshotDiff.earnsSnapshot(
                entries: [entry("save1.dat"), entry("save2.dat")],
                previous: manifest([entry("save1.dat")])))
    }

    func testAPathThatLeftEarnsASnapshot() {
        XCTAssertTrue(
            SnapshotDiff.earnsSnapshot(
                entries: [entry("save1.dat")],
                previous: manifest([entry("save1.dat"), entry("save2.dat")])))
    }

    func testAPathThatStoppedBeingPartialEarnsASnapshot() {
        XCTAssertTrue(
            SnapshotDiff.earnsSnapshot(
                entries: [entry("save1.dat", partial: false)],
                previous: manifest([entry("save1.dat", partial: true)])))
    }

    func testTheFirstSnapshotOfANonEmptySetIsEarned() {
        XCTAssertTrue(SnapshotDiff.earnsSnapshot(entries: [entry("save1.dat")], previous: nil))
        XCTAssertFalse(SnapshotDiff.earnsSnapshot(entries: [], previous: nil))
    }

    func testTwoRootsWithTheSamePathDoNotCollide() {
        let shared = BackupSetMember(
            root: .sharedData, path: "save1.dat", size: 10, modifiedAt: stamp)
        let plan = SnapshotDiff.plan(
            members: [member("save1.dat"), shared],
            previous: manifest([entry("save1.dat")]))

        XCTAssertEqual(plan.changed.map(\.root), [.sharedData])
        XCTAssertEqual(plan.reused.map(\.root), [.container])
    }
}

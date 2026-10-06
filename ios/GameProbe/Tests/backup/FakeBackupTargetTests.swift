import Foundation
import XCTest

@testable import GameProbe

/// The on-disk fake target, which every later backup ticket proves
/// itself against. It meets the whole protocol of SPEC section 8.
final class FakeBackupTargetTests: XCTestCase {

    private var tempRoot: URL!
    private var localRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let manager = FileManager.default
        tempRoot = manager.temporaryDirectory
            .appendingPathComponent("FakeBackupTargetTests-\(UUID().uuidString)", isDirectory: true)
        localRoot = tempRoot.appendingPathComponent("local", isDirectory: true)
        try manager.createDirectory(at: localRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTarget(
        capabilities: TargetCapabilities = TargetCapabilities(),
        quotaLimitBytes: Int64? = nil,
        confirmsLater: Bool = false
    ) -> FakeBackupTarget {
        FakeBackupTarget(
            directory: tempRoot.appendingPathComponent("target", isDirectory: true),
            capabilities: capabilities,
            quotaLimitBytes: quotaLimitBytes,
            confirmsLater: confirmsLater,
            clock: FakeBackupClock())
    }

    private func localFile(_ text: String, named name: String = UUID().uuidString) throws -> URL {
        let url = localRoot.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private func text(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private let blobPath = "Empo/devices/ns1/blobs/ab/abcdef"
    private let manifestPath = "Empo/devices/ns1/games/aa11/20260501T101500Z-0a1b2c.json"

    // MARK: - The six operations

    func testEveryOperationRunsOnAFreshRoot() async throws {
        let target = makeTarget(quotaLimitBytes: 1_000_000)

        let empty = try await target.list(prefix: "Empo/")
        XCTAssertTrue(empty.isEmpty)

        try await target.put(localFile: try localFile("save one"), path: blobPath)

        let listed = try await target.list(prefix: "Empo/")
        XCTAssertEqual(listed.map(\.path), [blobPath])
        XCTAssertEqual(listed[0].sizeBytes, Int64("save one".utf8.count))
        XCTAssertNotNil(listed[0].modifiedAt)

        let confirmation = try await target.confirm(path: blobPath)
        XCTAssertEqual(confirmation, .confirmed)

        let downloaded = localRoot.appendingPathComponent("downloaded")
        try await target.get(path: blobPath, localFile: downloaded)
        XCTAssertEqual(text(of: downloaded), "save one")

        let quota = try await target.quota()
        XCTAssertEqual(quota, QuotaReading(usedBytes: 8, limitBytes: 1_000_000))
        XCTAssertEqual(quota?.freeBytes, 999_992)

        try await target.delete(paths: [blobPath])
        let afterDelete = try await target.list(prefix: "Empo/")
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testASecondTargetReadsWhatTheFirstOneWroteOnTheSameRoot() async throws {
        let first = makeTarget()
        try await first.put(localFile: try localFile("kept"), path: blobPath)

        let second = makeTarget()
        let listed = try await second.list(prefix: "Empo/devices/ns1/blobs/")
        XCTAssertEqual(listed.map(\.path), [blobPath])

        let downloaded = localRoot.appendingPathComponent("again")
        try await second.get(path: blobPath, localFile: downloaded)
        XCTAssertEqual(text(of: downloaded), "kept")
    }

    func testAPrefixNarrowsTheListing() async throws {
        let target = makeTarget()
        try await target.put(localFile: try localFile("blob"), path: blobPath)
        try await target.put(localFile: try localFile("manifest"), path: manifestPath)

        let blobs = try await target.list(prefix: "Empo/devices/ns1/blobs/")
        XCTAssertEqual(blobs.map(\.path), [blobPath])

        let everything = try await target.list(prefix: "")
        XCTAssertEqual(everything.count, 2)
    }

    func testAPutOverAnExistingPathReplacesIt() async throws {
        let target = makeTarget()
        try await target.put(localFile: try localFile("first"), path: blobPath)
        try await target.put(localFile: try localFile("second"), path: blobPath)

        let downloaded = localRoot.appendingPathComponent("replaced")
        try await target.get(path: blobPath, localFile: downloaded)
        XCTAssertEqual(text(of: downloaded), "second")
    }

    func testGetAndConfirmOnAMissingPathReportNotFound() async throws {
        let target = makeTarget()

        do {
            _ = try await target.confirm(path: blobPath)
            XCTFail("a missing object must report notFound")
        } catch {
            XCTAssertEqual(error, .notFound)
        }

        do {
            try await target.get(
                path: blobPath, localFile: localRoot.appendingPathComponent("nothing"))
            XCTFail("a missing object must report notFound")
        } catch {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testDeletingAPathThatHoldsNothingIsNotAnError() async throws {
        let target = makeTarget()

        // The delete has already got what it asked for.
        try await target.delete(paths: [blobPath, manifestPath])
    }

    func testATargetThatAnswersNoSpaceQueryReturnsNothing() async throws {
        let target = makeTarget(quotaLimitBytes: nil)

        let quota = try await target.quota()
        XCTAssertNil(quota)
    }

    // MARK: - Atomicity, per 8.2

    func testAPutInterruptedAtTheCommitPointLeavesTheOldContent() async throws {
        let target = makeTarget()
        try await target.put(localFile: try localFile("old"), path: blobPath)

        await target.addFault(
            FakeTargetFault(operation: .put, error: .offline, phase: .commit))

        let newFile = try localFile("new")
        do {
            try await target.put(localFile: newFile, path: blobPath)
            XCTFail("the commit must fail")
        } catch {
            XCTAssertEqual(error, .offline)
        }

        let downloaded = localRoot.appendingPathComponent("after")
        try await target.get(path: blobPath, localFile: downloaded)
        XCTAssertEqual(text(of: downloaded), "old", "a reader never sees a torn write")

        let listed = try await target.list(prefix: "Empo/")
        XCTAssertEqual(listed.map(\.path), [blobPath], "the staged copy is not an object")
        XCTAssertEqual(listed[0].sizeBytes, 3)
    }

    func testAPutInterruptedBeforeTheTransferWritesNothing() async throws {
        let target = makeTarget()
        await target.addFault(FakeTargetFault(operation: .put, error: .offline))

        let newFile = try localFile("new")
        do {
            try await target.put(localFile: newFile, path: blobPath)
            XCTFail("the put must fail")
        } catch {
            XCTAssertEqual(error, .offline)
        }

        let listed = try await target.list(prefix: "")
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - The capability flags, per 8.3

    func testAPutOverTheMaxFileSizeIsRejectedBeforeAnyBytesMove() async throws {
        let target = makeTarget(capabilities: TargetCapabilities(maxFileSize: 4))

        let bigFile = try localFile("more than four")
        do {
            try await target.put(localFile: bigFile, path: blobPath)
            XCTFail("a file over the limit must be rejected")
        } catch {
            guard case .rejected = error else {
                return XCTFail("a file over the limit is a permanent refusal: \(error)")
            }
        }

        let listed = try await target.list(prefix: "")
        XCTAssertTrue(listed.isEmpty)
        let peak = await target.peakInFlight
        XCTAssertEqual(peak, 0, "no transfer started")
    }

    func testAFileAtTheMaxFileSizeStillLands() async throws {
        let target = makeTarget(capabilities: TargetCapabilities(maxFileSize: 4))

        try await target.put(localFile: try localFile("four"), path: blobPath)

        let listed = try await target.list(prefix: "")
        XCTAssertEqual(listed.map(\.path), [blobPath])
    }

    func testATargetThatReportsNoObjectAgeListsNoModifiedTime() async throws {
        let target = makeTarget(capabilities: TargetCapabilities(reportsObjectAge: false))
        try await target.put(localFile: try localFile("blob"), path: blobPath)

        let listed = try await target.list(prefix: "")
        XCTAssertNil(listed[0].modifiedAt)
        XCTAssertEqual(listed[0].sizeBytes, 4)
    }

    func testTheFlagsReachTheEngineWithoutAnAwait() {
        let capabilities = TargetCapabilities(
            canQueryQuota: true,
            reportsObjectAge: true,
            supportsBackgroundTransfer: false,
            maxFileSize: 150 * 1024 * 1024,
            foldsCase: true)
        let target = makeTarget(capabilities: capabilities)

        XCTAssertEqual(target.capabilities, capabilities)
    }

    // MARK: - Confirmation, per 8.5

    func testATargetThatConfirmsLaterHoldsItsPutPending() async throws {
        let target = makeTarget(confirmsLater: true)
        try await target.put(localFile: try localFile("blob"), path: blobPath)

        let pending = try await target.confirm(path: blobPath)
        XCTAssertEqual(pending, .pending, "the bytes left, the remote has not said so yet")

        await target.finishPendingUploads()

        let confirmed = try await target.confirm(path: blobPath)
        XCTAssertEqual(confirmed, .confirmed)
    }

    // MARK: - The crash point of 5.8

    func testEveryBlobLandsAndTheManifestDoesNot() async throws {
        let target = makeTarget()
        await target.addFault(FakeTargetFault.crashBeforeTheManifest())

        try await target.put(localFile: try localFile("blob one"), path: blobPath)
        try await target.put(
            localFile: try localFile("blob two"), path: "Empo/devices/ns1/blobs/cd/cdef01")

        let manifestFile = try localFile("{}")
        do {
            try await target.put(localFile: manifestFile, path: manifestPath)
            XCTFail("the manifest must not land")
        } catch {
            XCTAssertEqual(error, .offline)
        }

        let blobs = try await target.list(prefix: "Empo/devices/ns1/blobs/")
        XCTAssertEqual(blobs.count, 2, "an interrupted run only wastes space")
        let manifests = try await target.list(prefix: "Empo/devices/ns1/games/")
        XCTAssertTrue(manifests.isEmpty)
    }

    // MARK: - The second writer of 5.12

    func testASeededWriterClaimNamesAnotherDevice() async throws {
        let target = makeTarget()
        let claimPath = "Empo/devices/ns1/writer.json"
        try await target.seed(
            path: claimPath, contents: Data(#"{"deviceName":"Another iPhone"}"#.utf8))

        let read = await target.contents(atPath: claimPath)
        XCTAssertEqual(
            read.flatMap { String(data: $0, encoding: .utf8) }, #"{"deviceName":"Another iPhone"}"#)

        let listed = try await target.list(prefix: claimPath)
        XCTAssertEqual(listed.map(\.path), [claimPath])
    }

    // MARK: - The error kinds, per 8.4

    func testEachErrorKindFiresOnAChosenOperation() async throws {
        let kinds: [BackupProviderError] = [
            .authExpired, .outOfSpace, .throttled(retryAfter: 3), .offline,
            .permissionDenied, .notFound, .rejected(message: "the bucket is read-only"),
        ]

        for kind in kinds {
            let target = makeTarget(quotaLimitBytes: 10)
            await target.addFault(FakeTargetFault(operation: .quota, error: kind))

            do {
                _ = try await target.quota()
                XCTFail("the fault must fire: \(kind)")
            } catch {
                XCTAssertEqual(error, kind)
            }
        }
    }

    func testAFaultWithACountFiresThatManyTimes() async throws {
        let target = makeTarget()
        // Not a throttle: the gate retries those on its own, per
        // 8.6, so one that clears never reaches the caller.
        await target.addFault(FakeTargetFault(operation: .put, error: .offline, times: 1))

        let blobFile = try localFile("blob")
        do {
            try await target.put(localFile: blobFile, path: blobPath)
            XCTFail("the first put must fail")
        } catch {
            XCTAssertEqual(error, .offline)
        }

        try await target.put(localFile: blobFile, path: blobPath)
        let listed = try await target.list(prefix: "")
        XCTAssertEqual(listed.map(\.path), [blobPath])
    }

    func testAFaultOnAPathLeavesEveryOtherPathAlone() async throws {
        let target = makeTarget()
        await target.addFault(
            FakeTargetFault(operation: .get, error: .notFound, pathContains: "/games/"))
        try await target.put(localFile: try localFile("blob"), path: blobPath)
        try await target.put(localFile: try localFile("manifest"), path: manifestPath)

        try await target.get(
            path: blobPath, localFile: localRoot.appendingPathComponent("blob-copy"))

        do {
            try await target.get(
                path: manifestPath,
                localFile: localRoot.appendingPathComponent("manifest-copy"))
            XCTFail("the fault must fire on the manifest")
        } catch {
            XCTAssertEqual(error, .notFound)
        }
    }

    // MARK: - The in-flight limit, per 8.6

    func testTheTargetRunsAtMostFourTransfersAtOnce() async throws {
        let target = makeTarget()
        let latch = TransferLatch()
        await target.setLatch(latch)
        let files = try (0..<12).map { try localFile("blob \($0)", named: "blob-\($0)") }

        await withTaskGroup(of: Void.self) { group in
            for (index, file) in files.enumerated() {
                group.addTask {
                    try? await target.put(
                        localFile: file, path: "Empo/devices/ns1/blobs/ab/abcd\(index)")
                }
            }

            let arrived = await latch.waitForArrivals(4)
            XCTAssertTrue(arrived)
            let held = await latch.arrivedCount
            XCTAssertEqual(held, 4)

            await latch.open()
        }

        let peak = await target.peakInFlight
        XCTAssertEqual(peak, 4)
        let listed = try await target.list(prefix: "")
        XCTAssertEqual(listed.count, 12)
    }

    func testAThrottleAtTheCommitIsHonoredToo() async throws {
        let clock = FakeBackupClock()
        let target = FakeBackupTarget(
            directory: tempRoot.appendingPathComponent("commit", isDirectory: true),
            clock: clock,
            attempts: 3)
        // A real provider commits with a request of its own, and
        // that request answers 429 like any other.
        await target.addFault(
            FakeTargetFault(
                operation: .put, error: .throttled(retryAfter: 6), phase: .commit, times: 2))

        try await target.put(localFile: try localFile("blob"), path: blobPath)

        let waits = await clock.waits
        XCTAssertEqual(waits, [6, 6])
        let listed = try await target.list(prefix: "")
        XCTAssertEqual(listed.map(\.path), [blobPath])
    }

    func testAThrottledListIsHonoredAndTakesNoTransferSlot() async throws {
        let clock = FakeBackupClock()
        let target = FakeBackupTarget(
            directory: tempRoot.appendingPathComponent("listed", isDirectory: true),
            clock: clock,
            attempts: 3)
        await target.addFault(
            FakeTargetFault(operation: .list, error: .throttled(retryAfter: 2), times: 2))

        let listed = try await target.list(prefix: "")

        XCTAssertTrue(listed.isEmpty)
        let waits = await clock.waits
        XCTAssertEqual(waits, [2, 2])
        let peak = await target.peakInFlight
        XCTAssertEqual(peak, 0, "a list moves no file")
    }

    func testAThrottledDeleteAndQuotaAreHonoredToo() async throws {
        let clock = FakeBackupClock()
        let target = FakeBackupTarget(
            directory: tempRoot.appendingPathComponent("batch", isDirectory: true),
            quotaLimitBytes: 500,
            clock: clock,
            attempts: 2)
        await target.addFault(
            FakeTargetFault(operation: .delete, error: .throttled(retryAfter: 3), times: 1))
        await target.addFault(
            FakeTargetFault(operation: .quota, error: .throttled(retryAfter: 8), times: 1))

        try await target.put(localFile: try localFile("blob"), path: blobPath)
        try await target.delete(paths: [blobPath])
        let quota = try await target.quota()

        XCTAssertEqual(quota, QuotaReading(usedBytes: 0, limitBytes: 500))
        let waits = await clock.waits
        XCTAssertEqual(waits, [3, 8])
    }

    func testTheTargetHonorsRetryAfterWithNoRealSleep() async throws {
        let clock = FakeBackupClock()
        let target = FakeBackupTarget(
            directory: tempRoot.appendingPathComponent("throttled", isDirectory: true),
            clock: clock,
            attempts: 3)
        await target.addFault(
            FakeTargetFault(
                operation: .put, error: .throttled(retryAfter: 9), phase: .upload,
                times: 2))

        try await target.put(localFile: try localFile("blob"), path: blobPath)

        let waits = await clock.waits
        XCTAssertEqual(waits, [9, 9])
        let listed = try await target.list(prefix: "")
        XCTAssertEqual(listed.map(\.path), [blobPath])
    }
}

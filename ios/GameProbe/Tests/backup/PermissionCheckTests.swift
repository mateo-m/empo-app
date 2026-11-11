import Foundation
import XCTest

@testable import GameProbe

/// The add-time permission check of SPEC 8.7, as the add sheet of
/// 13.7 shows it.
final class PermissionCheckTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionCheckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeTarget(quotaLimitBytes: Int64? = 4_000_000) -> FakeBackupTarget {
        FakeBackupTarget(
            directory: tempRoot.appendingPathComponent("target", isDirectory: true),
            quotaLimitBytes: quotaLimitBytes,
            clock: FakeBackupClock())
    }

    private func run(on target: some BackupProvider) async -> PermissionCheckResult {
        await PermissionCheck.run(
            on: target,
            probePath: "Empo/permission-check-0a1b2c3d",
            scratchDirectory: tempRoot.appendingPathComponent("scratch", isDirectory: true))
    }

    private func outcome(
        _ result: PermissionCheckResult, _ step: PermissionCheckStep
    ) -> PermissionCheckOutcome? {
        result.steps.first { $0.step == step }?.outcome
    }

    // MARK: - The passing check

    func testTheCheckPassesOnAWritableRoot() async {
        let result = await run(on: makeTarget())

        XCTAssertEqual(result.steps.map(\.step), [.write, .list, .delete, .freeSpace])
        XCTAssertTrue(result.steps.allSatisfy { $0.outcome == .passed })
        XCTAssertNil(result.failedStep)
        XCTAssertTrue(result.allowsAdd)
        XCTAssertTrue(result.canQueryQuota)
        // The step runs after the delete, so the probe is gone.
        XCTAssertEqual(result.quota, QuotaReading(usedBytes: 0, limitBytes: 4_000_000))
    }

    func testTheCheckLeavesNoProbeBehind() async throws {
        let target = makeTarget()

        _ = await run(on: target)

        let listed = try await target.list(prefix: "")
        XCTAssertTrue(listed.isEmpty, "the check deletes what it wrote")
    }

    func testTheStepsCarryTheWordsTheAddSheetShows() async {
        let result = await run(on: makeTarget())

        XCTAssertEqual(result.steps.map(\.label), ["Save a test file", "Find the test file", "Delete the test file", "Read the free space"])
    }

    // MARK: - One failing step at a time

    func testTheWriteStepFailsAlone() async {
        let target = makeTarget()
        await target.addFault(FakeTargetFault(operation: .put, error: .permissionDenied))

        let result = await run(on: target)

        XCTAssertEqual(result.failedStep, .write)
        XCTAssertEqual(result.failure, .permissionDenied)
        XCTAssertEqual(outcome(result, .list), .notRun)
        XCTAssertEqual(outcome(result, .delete), .notRun)
        XCTAssertEqual(outcome(result, .freeSpace), .notRun)
        XCTAssertFalse(result.allowsAdd)
    }

    func testTheListStepFailsAlone() async {
        let target = makeTarget()
        await target.addFault(FakeTargetFault(operation: .list, error: .authExpired))

        let result = await run(on: target)

        XCTAssertEqual(outcome(result, .write), .passed)
        XCTAssertEqual(result.failedStep, .list)
        XCTAssertEqual(result.failure, .authExpired)
        XCTAssertEqual(outcome(result, .delete), .notRun)
        XCTAssertFalse(result.allowsAdd)
    }

    func testTheListStepFailsWhenTheProbeDoesNotShowUp() async {
        // A root that takes the write and then shows nothing is a
        // root Empo cannot read back.
        let result = await run(on: SwallowingTarget())

        XCTAssertEqual(outcome(result, .write), .passed)
        XCTAssertEqual(result.failedStep, .list)
        XCTAssertEqual(result.failure, .notFound)
        XCTAssertFalse(result.allowsAdd)
    }

    func testTheDeleteStepFailsAlone() async {
        let target = makeTarget()
        await target.addFault(FakeTargetFault(operation: .delete, error: .permissionDenied))

        let result = await run(on: target)

        XCTAssertEqual(outcome(result, .write), .passed)
        XCTAssertEqual(outcome(result, .list), .passed)
        XCTAssertEqual(result.failedStep, .delete)
        XCTAssertEqual(result.failure, .permissionDenied)
        XCTAssertEqual(outcome(result, .freeSpace), .notRun)
        XCTAssertFalse(result.allowsAdd)
    }

    func testTheFreeSpaceStepFailsAloneAndStillAllowsTheAdd() async {
        let target = makeTarget()
        await target.addFault(
            FakeTargetFault(operation: .quota, error: .rejected(message: "no quota call here")))

        let result = await run(on: target)

        XCTAssertEqual(result.failedStep, .freeSpace)
        XCTAssertEqual(result.failure, .rejected(message: "no quota call here"))
        // A target that answers no space query is a supported
        // target. It finds its limit at the first upload error, per
        // 9.7.
        XCTAssertTrue(result.allowsAdd)
        XCTAssertFalse(result.canQueryQuota)
    }

    func testATargetThatAnswersNoSpaceQuerySkipsTheStep() async {
        let result = await run(on: makeTarget(quotaLimitBytes: nil))

        XCTAssertEqual(outcome(result, .freeSpace), .skipped)
        XCTAssertNil(result.failedStep)
        XCTAssertTrue(result.allowsAdd)
        XCTAssertFalse(result.canQueryQuota)
    }

    func testARejectedMessageReachesTheUserWordForWord() async {
        let target = makeTarget()
        await target.addFault(
            FakeTargetFault(operation: .put, error: .rejected(message: "the bucket is read-only")))

        let result = await run(on: target)

        XCTAssertEqual(result.failure?.runStop, .rejected(message: "the bucket is read-only"))
    }

    // MARK: - The probe path

    func testEachProbePathIsItsOwn() {
        let first = PermissionCheck.makeProbePath()
        let second = PermissionCheck.makeProbePath()

        XCTAssertTrue(first.hasPrefix("Empo/permission-check-"))
        XCTAssertNotEqual(first, second, "two devices must not delete each other's probe")
    }

    func testTheProbeSitsUnderTheTargetRoot() {
        let path = PermissionCheck.makeProbePath(root: "Documents/Empo Backups")

        // 8.7 puts the probe under the root. The provider adds no
        // prefix of its own, so the root belongs in the path, the
        // same way `BackupNamespacePaths` builds an engine path.
        XCTAssertTrue(path.hasPrefix("Documents/Empo Backups/Empo/permission-check-"))
    }

    func testAnEmptyRootPutsTheProbeAtTheTopOfTheTarget() {
        XCTAssertTrue(
            PermissionCheck.makeProbePath(root: "").hasPrefix("Empo/permission-check-"))
    }

    // MARK: - The local probe file

    func testTwoChecksStageTheirProbeUnderDifferentLocalNames() async {
        // Two checks share one staging folder. A shared name lets the
        // first one to finish delete the file the other still uploads.
        let target = RecordingTarget()
        let scratch = tempRoot.appendingPathComponent("scratch", isDirectory: true)
        _ = await PermissionCheck.run(on: target, scratchDirectory: scratch)
        _ = await PermissionCheck.run(on: target, scratchDirectory: scratch)

        let files = await target.localFiles
        XCTAssertEqual(files.count, 2)
        XCTAssertNotEqual(files.first, files.last)
    }

    func testALocalWriteThatFailsForAnotherReasonDoesNotSayTheDeviceIsFull() async throws {
        // A plain file where the staging folder should be makes the
        // folder creation fail with "file exists".
        let blocked = tempRoot.appendingPathComponent("blocked")
        try Data().write(to: blocked)

        let result = await PermissionCheck.run(on: makeTarget(), scratchDirectory: blocked)

        XCTAssertEqual(result.failedStep, .write)
        XCTAssertEqual(result.failure, .rejected(message: PermissionCheck.localWriteFailedMessage))
    }

    func testOnlyANoSpaceErrorReadsAsAFullDevice() {
        XCTAssertTrue(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)).isOutOfSpace)
        XCTAssertTrue(CocoaError(.fileWriteOutOfSpace).isOutOfSpace)
        XCTAssertFalse(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)).isOutOfSpace)
        XCTAssertFalse(CocoaError(.fileWriteNoPermission).isOutOfSpace)
    }
}

private actor RecordingTarget: BackupProvider {

    nonisolated let capabilities = TargetCapabilities()
    private(set) var localFiles: [URL] = []
    private var paths: Set<String> = []

    func list(prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        paths.filter { $0.hasPrefix(prefix) }
            .map { RemoteObject(path: $0, sizeBytes: 0, modifiedAt: nil) }
    }

    func put(localFile: URL, path: String) async throws(BackupProviderError) {
        localFiles.append(localFile)
        paths.insert(path)
    }

    func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation { .confirmed }

    func get(path: String, localFile: URL) async throws(BackupProviderError) {
        throw .notFound
    }

    func delete(paths: [String]) async throws(BackupProviderError) {
        self.paths.subtract(paths)
    }

    func quota() async throws(BackupProviderError) -> QuotaReading? { nil }
}

/// A provider that takes a write and keeps nothing. It is the one
/// case the list step of 8.7 exists to catch.
private struct SwallowingTarget: BackupProvider {

    let capabilities = TargetCapabilities()

    func list(prefix: String) async throws(BackupProviderError) -> [RemoteObject] { [] }

    func put(localFile: URL, path: String) async throws(BackupProviderError) {}

    func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation { .confirmed }

    func get(path: String, localFile: URL) async throws(BackupProviderError) {
        throw .notFound
    }

    func delete(paths: [String]) async throws(BackupProviderError) {}

    func quota() async throws(BackupProviderError) -> QuotaReading? { nil }
}

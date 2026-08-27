import Foundation
import XCTest

@testable import GameProbe

/// The Dropbox rules of SPEC 9.2.
///
/// The account needs a real sign-in, so these checks cover the parts
/// that do not: the framing, the paging, the batch limit, the error
/// map, and the throttle wait.
final class DropboxTests: XCTestCase {

    private let megabyte: Int64 = 1024 * 1024

    // MARK: - 1. The error map, per 8.4

    func testAnInvalidTokenAsksForASignIn() {
        let error = Dropbox.error(
            status: 401, errorSummary: "expired_access_token/")
        XCTAssertEqual(error, .authExpired)
        XCTAssertEqual(error.effect, .needsSignIn)
    }

    func testInsufficientSpaceRunsThePruneLadder() {
        let error = Dropbox.error(
            status: 409, errorSummary: "path/insufficient_space/")
        XCTAssertEqual(error, .outOfSpace)
        XCTAssertEqual(error.effect, .runPruneLadder)
    }

    func testTooManyRequestsCarriesTheStatedWait() {
        let error = Dropbox.error(
            status: 429, errorSummary: "too_many_requests/", retryAfterHeader: "17")
        XCTAssertEqual(error, .throttled(retryAfter: 17))
        XCTAssertEqual(error.effect, .waitAndKeepRun(seconds: 17))
    }

    func testAThrottleWithNoHeaderTakesTheDefaultWait() {
        let error = Dropbox.error(status: 429)
        XCTAssertEqual(error, .throttled(retryAfter: Dropbox.defaultRetryAfter))
    }

    func testARevokedScopeBlocksTheTarget() {
        let error = Dropbox.error(status: 403, errorSummary: "access_denied/")
        XCTAssertEqual(error, .permissionDenied)
        // A re-sign-in does not fix a revoked scope, per 8.4.
        XCTAssertEqual(error.effect, .blocked)
    }

    func testAMissingPathDropsTheObjectFromTheCache() {
        let error = Dropbox.error(status: 409, errorSummary: "path/not_found/")
        XCTAssertEqual(error, .notFound)
        XCTAssertEqual(error.effect, .dropFromCache)
    }

    func testAServerErrorRetriesOnTheNextPass() {
        XCTAssertEqual(Dropbox.error(status: 500), .offline)
    }

    func testAnUnknownReasonReachesTheUserWordForWord() {
        let error = Dropbox.error(status: 409, errorSummary: "path/malformed_path/")
        XCTAssertEqual(
            error, .rejected(message: "Dropbox answered 409: path/malformed_path/"))
        XCTAssertEqual(
            error.effect,
            .stopAndShow(message: "Dropbox answered 409: path/malformed_path/"))
    }

    func testTheErrorSummaryComesOutOfTheBody() {
        let body = Data(#"{"error_summary": "path/conflict/file/..."}"#.utf8)
        XCTAssertEqual(Dropbox.errorSummary(inBody: body), "path/conflict/file/...")
    }

    // MARK: - 2. Which upload path a file takes, per 9.2

    func testAFileUnderTheLimitTakesTheSingleUpload() {
        XCTAssertEqual(Dropbox.uploadPlan(forFileOfSize: 1), .single)
        XCTAssertEqual(
            Dropbox.uploadPlan(forFileOfSize: Dropbox.singleUploadLimitBytes), .single)
    }

    func testAFileOverTheLimitTakesAnUploadSession() {
        let size = Dropbox.singleUploadLimitBytes + 1
        guard case .session(let chunks) = Dropbox.uploadPlan(forFileOfSize: size) else {
            return XCTFail("a file over 150 MiB has to take a session")
        }
        XCTAssertEqual(chunks.first?.offset, 0)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.length }, size)
        XCTAssertEqual(chunks.last?.isLast, true)
        XCTAssertEqual(chunks.filter(\.isLast).count, 1)
    }

    func testTheSingleUploadLimitIsTheOneNineTwoStates() {
        XCTAssertEqual(Dropbox.singleUploadLimitBytes, 150 * 1024 * 1024)
    }

    // MARK: - 3. A broken session resumes from its cursor

    func testAnInterruptedSessionResumesFromTheCursorAndNotFromZero() {
        let size = 100 * megabyte
        let done = 64 * megabyte
        let left = Dropbox.chunks(ofFileSize: size, from: done)

        XCTAssertEqual(left.first?.offset, done)
        XCTAssertEqual(left.reduce(0) { $0 + $1.length }, size - done)
        XCTAssertEqual(left.last?.endOffset, size)
    }

    func testACursorAtTheEndLeavesNoAppendAndStillHasToCommit() {
        XCTAssertTrue(Dropbox.chunks(ofFileSize: 10, from: 10).isEmpty)
    }

    func testDropboxReportsTheOffsetToResumeFrom() {
        let json =
            #"{"error_summary":"incorrect_offset/","#
            + #""error":{".tag":"incorrect_offset","correct_offset":67108864}}"#
        let body = Data(json.utf8)
        XCTAssertEqual(Dropbox.correctedOffset(inBody: body), 67_108_864)
    }

    func testAFailureThatIsNotAnOffsetReportsNoOffset() {
        let body = Data(#"{"error_summary":"path/not_found/"}"#.utf8)
        XCTAssertNil(Dropbox.correctedOffset(inBody: body))
    }

    // MARK: - 4. Paging, per 9.2

    func testEveryObjectAcrossMoreThanOnePageReachesTheCaller() {
        let first = page(names: ["Empo/a", "Empo/b"], cursor: "c1", hasMore: true)
        let second = page(names: ["Empo/c"], cursor: "c2", hasMore: false)

        let objects = Dropbox.objects(fromPages: [first, second], prefix: "Empo/")
        XCTAssertEqual(objects.map(\.path), ["Empo/a", "Empo/b", "Empo/c"])
    }

    func testAListReportsNoFolderAndNoDeletion() {
        let entries = [
            DropboxEntry(tag: "folder", path: "/Empo/games", sizeBytes: 0, serverModified: nil),
            DropboxEntry(tag: "deleted", path: "/Empo/gone", sizeBytes: 0, serverModified: nil),
            DropboxEntry(tag: "file", path: "/Empo/kept", sizeBytes: 4, serverModified: nil),
        ]
        let objects = Dropbox.objects(
            fromPages: [DropboxListPage(entries: entries, cursor: "", hasMore: false)],
            prefix: "Empo/")
        XCTAssertEqual(objects.map(\.path), ["Empo/kept"])
    }

    func testAPageCarriesTheSizeAndTheObjectAge() {
        let json =
            #"{"entries":[{".tag":"file","path_display":"/Empo/x","size":7,"#
            + #""server_modified":"2026-08-27T14:30:00Z"}],"#
            + #""cursor":"c","has_more":true}"#
        let body = Data(json.utf8)
        guard let page = Dropbox.page(fromBody: body) else {
            return XCTFail("the page has to read")
        }
        XCTAssertEqual(page.cursor, "c")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.entries.first?.sizeBytes, 7)
        XCTAssertEqual(
            page.entries.first?.serverModified,
            Dropbox.date(fromTimestamp: "2026-08-27T14:30:00Z"))
    }

    // MARK: - 5. delete_batch splits

    func testABatchOverTheAPILimitSplits() {
        let paths = (0..<2500).map { "Empo/blob-\($0)" }
        let batches = Dropbox.deleteBatches(paths: paths)

        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches.map(\.count), [1000, 1000, 500])
        XCTAssertEqual(batches.flatMap { $0 }, paths)
    }

    func testADeleteOfNothingSendsNoBatch() {
        XCTAssertTrue(Dropbox.deleteBatches(paths: []).isEmpty)
    }

    // MARK: - 6. Retry-After, with a fake clock and no real sleep

    func testTheGateHonorsRetryAfterWithoutSleeping() async throws {
        let clock = RecordingClock()
        let gate = TransferGate(attempts: 3, clock: clock)
        let service = ThrottlingService(throttles: 2, retryAfter: 30)

        let answer = try await gate.request { () async throws(BackupProviderError) -> String in
            try await service.call()
        }

        let waits = await clock.waits
        let gateWaits = await gate.waitedSeconds
        XCTAssertEqual(answer, "ok")
        XCTAssertEqual(waits, [30, 30])
        XCTAssertEqual(gateWaits, [30, 30])
    }

    func testAServiceThatKeepsThrottlingReachesTheEngine() async {
        let clock = RecordingClock()
        let gate = TransferGate(attempts: 2, clock: clock)
        let service = ThrottlingService(throttles: 5, retryAfter: 9)

        do {
            _ = try await gate.request { () async throws(BackupProviderError) -> String in
                try await service.call()
            }
            XCTFail("a service that keeps throttling has to reach the engine")
        } catch {
            XCTAssertEqual(error, .throttled(retryAfter: 9))
        }
    }

    // MARK: - 7. The capability flags, per section 9

    func testTheCapabilityFlagsReadAsSectionNineStates() {
        let flags = Dropbox.capabilities
        XCTAssertTrue(flags.canQueryQuota)
        XCTAssertTrue(flags.reportsObjectAge)
        XCTAssertTrue(flags.supportsBackgroundTransfer)
        XCTAssertTrue(flags.foldsCase)
        XCTAssertEqual(flags.maxFileSize, 2 * 1024 * 1024 * 1024 * 1024)
    }

    func testAFileOverTwoTebibytesIsRefusedAndNotCalledOutOfSpace() {
        let rejection = Dropbox.capabilities.rejection(
            forFileOfSize: Dropbox.maxFileSizeBytes + 1)
        guard case .rejected = rejection else {
            return XCTFail("a file over the limit is a permanent refusal, per 8.3")
        }
    }

    // MARK: - Case folding, per 9.2 and 5.2

    func testNoNameEmpoWritesCollidesUnderCaseFolding() {
        var names: Set<String> = [
            BackupNamespacePaths.empoDirectoryName,
            BackupNamespacePaths.formatFileName,
            BackupNamespacePaths.devicesDirectoryName,
            BackupNamespacePaths.writerFileName,
            BackupNamespacePaths.deviceFileName,
            BackupNamespacePaths.gamesDirectoryName,
            BackupNamespacePaths.preferencesDirectoryName,
        ]

        let paths = BackupNamespacePaths(
            root: Dropbox.root, namespaceId: BackupKeys.makeNamespaceId())
        for index in 0..<200 {
            let key = BackupKeys.gameKey(containerFolderName: "game-\(index)")
            let stamp = Date(timeIntervalSince1970: TimeInterval(index) * 3600)
            let snapshot = BackupKeys.snapshotId(
                date: stamp, suffix: BackupKeys.randomHex(characters: 6))
            names.insert(paths.manifestPath(stream: .game(key: key), snapshotId: snapshot))
            names.insert(paths.manifestPath(stream: .preferences, snapshotId: snapshot))
            names.insert(
                paths.blobPath(hash: BackupKeys.randomHex(characters: 64), fanOutWidth: 2))
        }

        // Folding maps two distinct names onto one only when the two
        // differ by case alone. Empo writes hex and fixed ASCII, per
        // 5.2, so the set keeps its size.
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, names.count)
    }

    // MARK: - Paths

    func testAnAPIPathCarriesOneLeadingSeparator() {
        XCTAssertEqual(Dropbox.apiPath(for: "Empo/format.json"), "/Empo/format.json")
        XCTAssertEqual(Dropbox.apiPath(for: "/Empo/format.json"), "/Empo/format.json")
    }

    func testTheAppFolderRootIsTheEmptyStringAndNotASeparator() {
        // `list_folder` on "/" is an error. The app folder root is "".
        XCTAssertEqual(Dropbox.apiPath(for: ""), "")
        XCTAssertEqual(Dropbox.apiPath(for: "/"), "")
    }

    func testTheDescriptorRootIsEmptyBecauseTheAppFolderIsTheRoot() {
        XCTAssertEqual(Dropbox.root, "")
        XCTAssertEqual(Dropbox.displayRoot, "/Apps/Empo")
        XCTAssertEqual(
            BackupNamespacePaths(root: Dropbox.root, namespaceId: "n").empoPrefix, "Empo")
    }

    func testAListStartsAtTheDeepestFolderThePrefixNames() {
        XCTAssertEqual(
            Dropbox.listFolder(forPrefix: "Empo/devices/ns/games/key/"),
            "/Empo/devices/ns/games/key")
        XCTAssertEqual(Dropbox.listFolder(forPrefix: "Empo/permission-check-a1"), "/Empo")
        // The app folder root is "", because `list_folder` on "/" is
        // an error.
        XCTAssertEqual(Dropbox.listFolder(forPrefix: "Empo"), "")
    }

    func testAHeaderArgumentCarriesASCIIAlone() {
        XCTAssertEqual(Dropbox.headerSafe(#"{"path":"/Empo/a"}"#), #"{"path":"/Empo/a"}"#)
        XCTAssertEqual(Dropbox.headerSafe(#"{"path":"/Empo/né"}"#), #"{"path":"/Empo/n\u00e9"}"#)
    }

    // MARK: - Helpers

    private func page(names: [String], cursor: String, hasMore: Bool) -> DropboxListPage {
        DropboxListPage(
            entries: names.map {
                DropboxEntry(tag: "file", path: "/" + $0, sizeBytes: 1, serverModified: nil)
            },
            cursor: cursor, hasMore: hasMore)
    }
}

/// A clock that records a wait and returns at once.
private actor RecordingClock: BackupClock {
    private(set) var waits: [TimeInterval] = []

    func wait(seconds: TimeInterval) async {
        waits.append(seconds)
    }
}

/// A service that throttles a stated number of times, then answers.
private actor ThrottlingService {
    private var left: Int
    private let retryAfter: TimeInterval

    init(throttles: Int, retryAfter: TimeInterval) {
        self.left = throttles
        self.retryAfter = retryAfter
    }

    func call() throws(BackupProviderError) -> String {
        guard left == 0 else {
            left -= 1
            throw .throttled(retryAfter: retryAfter)
        }
        return "ok"
    }
}

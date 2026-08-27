import Foundation
import XCTest

@testable import GameProbe

/// The Google Drive rules of SPEC 9.3.
///
/// The account needs a real sign-in, so these checks cover the parts
/// that do not: the error map, the upload framing, the resume, the
/// paging, the space query, and the capability flags.
final class GoogleDriveTests: XCTestCase {

    private let megabyte: Int64 = 1024 * 1024

    private func failureBody(reason: String, message: String, code: Int) -> Data {
        let value: [String: Any] = [
            "error": [
                "code": code,
                "message": message,
                "errors": [["domain": "global", "reason": reason, "message": message]],
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }

    // MARK: - 1. The error map, per 8.4

    func testAFullAccountRunsThePruneLadder() {
        let body = failureBody(
            reason: "storageQuotaExceeded", message: "The user's Drive storage quota has been exceeded.",
            code: 403)
        let error = GoogleDrive.error(status: 403, failure: GoogleDrive.failure(inBody: body))
        XCTAssertEqual(error, .outOfSpace)
        XCTAssertEqual(error.effect, .runPruneLadder)
    }

    func testARevokedScopeBlocksTheTarget() {
        let body = failureBody(
            reason: "insufficientPermissions", message: "Insufficient Permission", code: 403)
        let error = GoogleDrive.error(status: 403, failure: GoogleDrive.failure(inBody: body))
        XCTAssertEqual(error, .permissionDenied)
        // A re-sign-in does not fix a revoked scope, per 8.4.
        XCTAssertEqual(error.effect, .blocked)
    }

    func testAnInvalidTokenAsksForASignIn() {
        let error = GoogleDrive.error(status: 401)
        XCTAssertEqual(error, .authExpired)
        XCTAssertEqual(error.effect, .needsSignIn)
    }

    func testATokenErrorInAFourOhThreeAlsoAsksForASignIn() {
        let body = failureBody(reason: "authError", message: "Invalid Credentials", code: 403)
        XCTAssertEqual(
            GoogleDrive.error(status: 403, failure: GoogleDrive.failure(inBody: body)),
            .authExpired)
    }

    func testTooManyRequestsCarriesTheStatedWait() {
        let error = GoogleDrive.error(status: 429, retryAfterHeader: "17")
        XCTAssertEqual(error, .throttled(retryAfter: 17))
        XCTAssertEqual(error.effect, .waitAndKeepRun(seconds: 17))
    }

    func testARateLimitInAFourOhThreeThrottles() {
        let body = failureBody(
            reason: "userRateLimitExceeded", message: "Rate Limit Exceeded", code: 403)
        let error = GoogleDrive.error(
            status: 403, failure: GoogleDrive.failure(inBody: body), attempt: 3)
        XCTAssertEqual(error, .throttled(retryAfter: GoogleDrive.backoffSeconds(attempt: 3)))
    }

    func testAMissingObjectDropsItFromTheCache() {
        let error = GoogleDrive.error(status: 404)
        XCTAssertEqual(error, .notFound)
        XCTAssertEqual(error.effect, .dropFromCache)
    }

    func testAServerErrorRetriesOnTheNextPass() {
        XCTAssertEqual(GoogleDrive.error(status: 500), .offline)
        XCTAssertEqual(GoogleDrive.error(status: 503), .offline)
    }

    func testAnUnknownReasonReachesTheUserWordForWord() {
        let body = failureBody(reason: "badRequest", message: "Invalid field selection", code: 400)
        let error = GoogleDrive.error(status: 400, failure: GoogleDrive.failure(inBody: body))
        XCTAssertEqual(
            error, .rejected(message: "Google Drive answered 400: Invalid field selection"))
        XCTAssertEqual(
            error.effect,
            .stopAndShow(message: "Google Drive answered 400: Invalid field selection"))
    }

    func testTheReasonAndTheMessageComeOutOfTheBody() {
        let body = failureBody(reason: "storageQuotaExceeded", message: "no room", code: 403)
        let failure = GoogleDrive.failure(inBody: body)
        XCTAssertEqual(failure.reason, "storageQuotaExceeded")
        XCTAssertEqual(failure.message, "no room")
    }

    func testABodyThatIsNotJSONStillMapsToAnErrorKind() {
        let failure = GoogleDrive.failure(inBody: Data("<html>gateway</html>".utf8))
        XCTAssertEqual(failure.reason, "")
        XCTAssertEqual(
            GoogleDrive.error(status: 502, failure: failure), .offline)
    }

    // MARK: - The truncated backoff of 9.3

    func testTheBackoffDoublesAndThenStopsAtTheCeiling() {
        XCTAssertEqual(GoogleDrive.backoffSeconds(attempt: 1), 1)
        XCTAssertEqual(GoogleDrive.backoffSeconds(attempt: 2), 2)
        XCTAssertEqual(GoogleDrive.backoffSeconds(attempt: 3), 4)
        XCTAssertEqual(GoogleDrive.backoffSeconds(attempt: 7), 64)
        XCTAssertEqual(
            GoogleDrive.backoffSeconds(attempt: 40), GoogleDrive.backoffCeilingSeconds)
    }

    func testAStatedRetryAfterBeatsTheBackoff() {
        XCTAssertEqual(GoogleDrive.retryAfterSeconds("30", attempt: 1), 30)
        XCTAssertEqual(GoogleDrive.retryAfterSeconds(nil, attempt: 4), 8)
        XCTAssertEqual(GoogleDrive.retryAfterSeconds("nonsense", attempt: 2), 2)
    }

    // MARK: - 2. Which upload path a file takes, per 9.3

    func testAFileUnderFiveMegabytesTakesTheSimpleUpload() {
        XCTAssertEqual(GoogleDrive.uploadPlan(forFileOfSize: 1), .simple)
        XCTAssertEqual(
            GoogleDrive.uploadPlan(forFileOfSize: GoogleDrive.simpleUploadLimitBytes), .simple)
    }

    func testAFileOverFiveMegabytesTakesAResumableUpload() {
        let size = GoogleDrive.simpleUploadLimitBytes + 1
        guard case .resumable(let chunks) = GoogleDrive.uploadPlan(forFileOfSize: size) else {
            return XCTFail("a file over 5 MB has to take a resumable upload")
        }
        XCTAssertEqual(chunks.first?.offset, 0)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.length }, size)
    }

    func testTheSimpleUploadLimitIsTheOneNineThreeStates() {
        XCTAssertEqual(GoogleDrive.simpleUploadLimitBytes, 5 * 1024 * 1024)
    }

    // MARK: - 3. Every chunk but the last is a multiple of 256 KB

    func testEveryChunkButTheLastIsAMultipleOfTheAlignment() {
        let size = 200 * megabyte + 7
        let chunks = GoogleDrive.chunks(ofFileSize: size, from: 0)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks.dropLast() {
            XCTAssertEqual(chunk.length % GoogleDrive.chunkAlignmentBytes, 0)
        }
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.length }, size)
    }

    func testTheChunkSizeIsItselfAMultipleOfTheAlignment() {
        XCTAssertEqual(GoogleDrive.uploadChunkBytes % GoogleDrive.chunkAlignmentBytes, 0)
        XCTAssertEqual(GoogleDrive.chunkAlignmentBytes, 256 * 1024)
    }

    func testOnlyTheLastChunkClosesTheSession() {
        let chunks = GoogleDrive.chunks(ofFileSize: 200 * megabyte, from: 0)
        XCTAssertEqual(chunks.filter(\.isLast).count, 1)
        XCTAssertEqual(chunks.last?.isLast, true)
        XCTAssertEqual(chunks.last?.endOffset, 200 * megabyte)
    }

    func testTheContentRangeNamesTheBytesAndTheWholeSize() {
        let chunk = GoogleDrive.Chunk(offset: 0, length: 262_144, isLast: false)
        XCTAssertEqual(
            GoogleDrive.contentRange(of: chunk, fileSize: 1_048_576),
            "bytes 0-262143/1048576")
    }

    // MARK: - 4. An interrupted upload resumes at the offset the probe reports

    func testTheProbeAsksHowFarTheSessionGot() {
        XCTAssertEqual(GoogleDrive.probeContentRange(fileSize: 1_048_576), "bytes */1048576")
    }

    func testTheRangeHeaderNamesTheOffsetToCarryOnFrom() {
        XCTAssertEqual(GoogleDrive.resumeOffset(fromRangeHeader: "bytes=0-262143"), 262_144)
        XCTAssertEqual(GoogleDrive.resumeOffset(fromRangeHeader: " bytes=0-99 "), 100)
    }

    func testASessionWithNoRangeHeaderHoldsNothingYet() {
        XCTAssertEqual(GoogleDrive.resumeOffset(fromRangeHeader: nil), 0)
        XCTAssertEqual(GoogleDrive.resumeOffset(fromRangeHeader: "bytes=*"), 0)
    }

    func testAnInterruptedUploadResumesFromTheCursorAndNotFromZero() {
        let size = 100 * megabyte
        let done = 64 * megabyte
        let left = GoogleDrive.chunks(ofFileSize: size, from: done)

        XCTAssertEqual(left.first?.offset, done)
        XCTAssertEqual(left.reduce(0) { $0 + $1.length }, size - done)
        XCTAssertEqual(left.last?.endOffset, size)
    }

    func testACursorAtTheEndLeavesNoChunk() {
        XCTAssertTrue(GoogleDrive.chunks(ofFileSize: 10, from: 10).isEmpty)
    }

    func testASavedCursorCarriesTheUploadOn() {
        let now = Date()
        let record = GoogleDriveUploadSession(
            sessionURI: "https://www.googleapis.com/upload/drive/v3/files?upload_id=x",
            offset: 64 * megabyte, fileSize: 100 * megabyte, startedAt: now)
        XCTAssertTrue(record.isUsable(at: now, forFileOfSize: 100 * megabyte))
    }

    // MARK: - 5. An expired session URI starts the upload again

    func testASessionDriveNoLongerHoldsStartsAgain() {
        XCTAssertTrue(GoogleDrive.isSessionGone(status: 404))
        XCTAssertTrue(GoogleDrive.isSessionGone(status: 410))
        XCTAssertFalse(GoogleDrive.isSessionGone(status: 308))
        XCTAssertFalse(GoogleDrive.isSessionGone(status: 200))
    }

    func testACursorOlderThanAWeekIsDeadWeight() {
        let now = Date()
        let record = GoogleDriveUploadSession(
            sessionURI: "https://upload", offset: 1, fileSize: 100,
            startedAt: now.addingTimeInterval(-GoogleDriveUploadSession.lifetime - 1))
        XCTAssertFalse(record.isUsable(at: now, forFileOfSize: 100))
    }

    func testACursorForAFileOfAnotherSizeIsDeadWeight() {
        let now = Date()
        let record = GoogleDriveUploadSession(
            sessionURI: "https://upload", offset: 10, fileSize: 100, startedAt: now)
        XCTAssertFalse(record.isUsable(at: now, forFileOfSize: 200))
    }

    func testTheSessionLifetimeIsTheWeekOfNineThree() {
        XCTAssertEqual(GoogleDriveUploadSession.lifetime, 7 * 24 * 60 * 60)
        XCTAssertEqual(GoogleDrive.uploadSessionLifetime, GoogleDriveUploadSession.lifetime)
    }

    // MARK: - 6. Paging returns every object across more than one page

    private func pageBody(names: [String], nextPageToken: String?) -> Data {
        var value: [String: Any] = [
            "files": names.enumerated().map { index, name in
                [
                    "id": "id-\(name)",
                    "name": name,
                    "size": "\(100 + index)",
                    "modifiedTime": "2026-08-27T10:00:00.000Z",
                    "mimeType": "application/octet-stream",
                ]
            }
        ]
        if let nextPageToken { value["nextPageToken"] = nextPageToken }
        return (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }

    func testPagingReturnsEveryObjectAcrossMoreThanOnePage() {
        let first = GoogleDrive.page(fromBody: pageBody(names: ["Empo/a", "Empo/b"], nextPageToken: "t2"))
        let second = GoogleDrive.page(fromBody: pageBody(names: ["Empo/c"], nextPageToken: nil))
        XCTAssertEqual(first?.hasMore, true)
        XCTAssertEqual(first?.nextPageToken, "t2")
        XCTAssertEqual(second?.hasMore, false)

        let objects = GoogleDrive.objects(
            fromPages: [first, second].compactMap { $0 }, prefix: "Empo/")
        XCTAssertEqual(objects.map(\.path), ["Empo/a", "Empo/b", "Empo/c"])
    }

    func testAPrefixReachesNoSecondStream() {
        let page = GoogleDrive.page(
            fromBody: pageBody(names: ["Empo/games/aa/one.json", "Empo/prefs/two.json"], nextPageToken: nil))
        let objects = GoogleDrive.objects(fromPages: [page].compactMap { $0 }, prefix: "Empo/games/")
        XCTAssertEqual(objects.map(\.path), ["Empo/games/aa/one.json"])
    }

    func testAFolderNeverReachesTheEngine() {
        let value: [String: Any] = [
            "files": [
                ["id": "f", "name": "Empo Backups", "mimeType": GoogleDrive.folderMimeType],
                ["id": "b", "name": "Empo/x", "size": "8", "mimeType": "application/octet-stream"],
            ]
        ]
        let body = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        let page = GoogleDrive.page(fromBody: body)
        XCTAssertEqual(
            GoogleDrive.objects(fromPages: [page].compactMap { $0 }, prefix: "").map(\.path),
            ["Empo/x"])
    }

    func testAPageCarriesTheSizeAndTheModifiedTime() {
        let page = GoogleDrive.page(fromBody: pageBody(names: ["Empo/a"], nextPageToken: nil))
        let objects = GoogleDrive.objects(fromPages: [page].compactMap { $0 }, prefix: "")
        XCTAssertEqual(objects.first?.sizeBytes, 100)
        XCTAssertNotNil(objects.first?.modifiedAt)
    }

    func testThePagesAnswerTheIdOfEveryPath() {
        let page = GoogleDrive.page(fromBody: pageBody(names: ["Empo/a", "Empo/b"], nextPageToken: nil))
        XCTAssertEqual(
            GoogleDrive.identifiers(fromPages: [page].compactMap { $0 }),
            ["Empo/a": "id-Empo/a", "Empo/b": "id-Empo/b"])
    }

    func testTheIdOfACreateComesOutOfTheBody() {
        XCTAssertEqual(GoogleDrive.fileId(inBody: Data(#"{"id":"abc"}"#.utf8)), "abc")
        XCTAssertEqual(
            GoogleDrive.fileId(inBody: Data(#"{"files":[{"id":"def"}]}"#.utf8)), "def")
        XCTAssertNil(GoogleDrive.fileId(inBody: Data(#"{"files":[]}"#.utf8)))
    }

    // MARK: - 7. The capability flags, per the table of section 9

    func testTheCapabilityFlagsReadAsSectionNineStates() {
        let flags = GoogleDrive.capabilities
        XCTAssertTrue(flags.canQueryQuota)
        XCTAssertTrue(flags.reportsObjectAge)
        XCTAssertTrue(flags.supportsBackgroundTransfer)
        XCTAssertFalse(flags.foldsCase)
        XCTAssertEqual(flags.maxFileSize, 5 * 1000 * 1000 * 1000 * 1000)
    }

    func testAFileOverFiveTerabytesIsARefusalAndNotALackOfSpace() {
        let rejection = GoogleDrive.capabilities.rejection(
            forFileOfSize: GoogleDrive.maxFileSizeBytes + 1)
        guard case .rejected = rejection else {
            return XCTFail("a file over the limit is a permanent refusal")
        }
    }

    // MARK: - The space query of 9.3

    func testTheSpaceQueryReadsTheStringsDriveSends() {
        let body = Data(
            #"{"storageQuota":{"limit":"16106127360","usage":"1073741824","usageInDrive":"1"}}"#
                .utf8)
        XCTAssertEqual(
            GoogleDrive.quota(fromBody: body),
            QuotaReading(usedBytes: 1_073_741_824, limitBytes: 16_106_127_360))
    }

    func testAnAccountWithNoStatedLimitStillAnswersItsUse() {
        let body = Data(#"{"storageQuota":{"usage":"42"}}"#.utf8)
        XCTAssertEqual(GoogleDrive.quota(fromBody: body)?.usedBytes, 42)
        XCTAssertNil(GoogleDrive.quota(fromBody: body)?.limitBytes)
    }

    // MARK: - The queries and the URLs

    func testTheRootIsTheFolderEmpoCreates() {
        XCTAssertEqual(GoogleDrive.rootFolderName, "Empo Backups")
        XCTAssertEqual(GoogleDrive.root, "")
        XCTAssertEqual(GoogleDrive.scope, "https://www.googleapis.com/auth/drive.file")
    }

    func testAQuotedValueEscapesTheQuoteThatWouldEndIt() {
        XCTAssertEqual(GoogleDrive.quoted("plain"), "'plain'")
        XCTAssertEqual(GoogleDrive.quoted("it's"), #"'it\'s'"#)
    }

    func testTheChildrenQueryAsksForOneFolderAndSkipsTheTrash() {
        let query = GoogleDrive.childrenQuery(parentId: "root-id")
        XCTAssertTrue(query.contains("'root-id' in parents"))
        XCTAssertTrue(query.contains("trashed = false"))
    }

    func testTheNameQueryFindsOnePath() {
        let query = GoogleDrive.nameQuery(name: "Empo/format.json", parentId: "root-id")
        XCTAssertTrue(query.contains("name = 'Empo/format.json'"))
        XCTAssertTrue(query.contains("'root-id' in parents"))
    }

    func testTheRootFolderQueryNamesNoParent() {
        let query = GoogleDrive.rootFolderQuery()
        XCTAssertTrue(query.contains("name = 'Empo Backups'"))
        XCTAssertTrue(query.contains(GoogleDrive.folderMimeType))
        XCTAssertFalse(query.contains("in parents"))
    }

    func testAListURLCarriesTheQueryTheFieldsAndThePageToken() {
        let url = GoogleDrive.filesListURL(query: "a = 'b'", pageToken: "tok")
        let text = url?.absoluteString ?? ""
        XCTAssertTrue(text.hasPrefix(GoogleDrive.filesEndpoint))
        XCTAssertTrue(text.contains("pageToken=tok"))
        XCTAssertTrue(text.contains("fields="))
    }

    func testAnUploadWithAnIdUpdatesTheFileThatAlreadyHoldsThePath() {
        let create = GoogleDrive.uploadURL(uploadType: "resumable")?.absoluteString ?? ""
        let update = GoogleDrive.uploadURL(uploadType: "resumable", fileId: "abc")?.absoluteString ?? ""
        XCTAssertTrue(create.hasPrefix(GoogleDrive.uploadEndpoint + "?"))
        XCTAssertTrue(update.hasPrefix(GoogleDrive.uploadEndpoint + "/abc?"))
        XCTAssertTrue(update.contains("uploadType=resumable"))
    }

    func testADownloadAsksForTheBytesAndNotTheMetadata() {
        let url = GoogleDrive.filesURL(id: "abc", alt: "media")?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/files/abc"))
        XCTAssertTrue(url.contains("alt=media"))
    }

    func testTheSpaceQueryURLAsksForTheStorageQuotaAlone() {
        let url = GoogleDrive.aboutURL()?.absoluteString ?? ""
        XCTAssertTrue(url.contains("fields=storageQuota"))
    }

    // MARK: - The OAuth callback of 8.10

    func testTheCallbackSchemeIsTheReversedClientId() {
        XCTAssertEqual(
            GoogleDrive.redirectScheme(clientId: "12345-abc.apps.googleusercontent.com"),
            "com.googleusercontent.apps.12345-abc")
        XCTAssertEqual(
            GoogleDrive.redirectURL(clientId: "12345-abc.apps.googleusercontent.com")?
                .absoluteString,
            "com.googleusercontent.apps.12345-abc:/oauth2redirect")
    }

    func testAClientIdInAnotherFormHasNoScheme() {
        XCTAssertNil(GoogleDrive.redirectScheme(clientId: ""))
        XCTAssertNil(GoogleDrive.redirectScheme(clientId: "12345-abc"))
        XCTAssertNil(GoogleDrive.redirectScheme(clientId: ".apps.googleusercontent.com"))
    }

    // MARK: - The multipart body of a simple upload

    func testTheMultipartBodyCarriesTheMetadataThenTheBytes() {
        let boundary = "BOUND"
        let metadata = GoogleDrive.metadata(name: "Empo/x", parentId: "root-id")
        let head = String(
            data: GoogleDrive.multipartHead(metadata: metadata, boundary: boundary),
            encoding: .utf8)
        let tail = String(
            data: GoogleDrive.multipartTail(boundary: boundary), encoding: .utf8)

        XCTAssertEqual(head?.hasPrefix("--BOUND\r\n"), true)
        XCTAssertEqual(head?.contains("application/json"), true)
        XCTAssertEqual(head?.contains(#""name":"Empo/x""#), true)
        XCTAssertEqual(head?.contains("application/octet-stream"), true)
        XCTAssertEqual(tail, "\r\n--BOUND--\r\n")
        XCTAssertEqual(
            GoogleDrive.multipartContentType(boundary: boundary),
            "multipart/related; boundary=BOUND")
    }

    func testTheMetadataNamesTheParentFolder() {
        let metadata = GoogleDrive.metadata(name: "Empo/x", parentId: "root-id")
        XCTAssertTrue(metadata.contains("root-id"))
        XCTAssertFalse(GoogleDrive.metadata(name: "Empo/x", parentId: nil).contains("parents"))
    }

    func testTheFolderMetadataAsksForAFolder() {
        let metadata = GoogleDrive.folderMetadata()
        XCTAssertTrue(metadata.contains(GoogleDrive.folderMimeType))
        XCTAssertTrue(metadata.contains("Empo Backups"))
    }

    func testTwoBoundariesAreNotTheSame() {
        XCTAssertNotEqual(GoogleDrive.multipartBoundary(), GoogleDrive.multipartBoundary())
    }
}

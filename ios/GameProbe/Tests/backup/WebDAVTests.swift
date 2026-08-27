import Foundation
import XCTest

@testable import GameProbe

/// The WebDAV rules of SPEC 9.5, and the per-server space query of
/// 9.7.
///
/// The server needs a password, so these checks cover the parts that
/// do not: the answer shapes of Nextcloud and Apache `mod_dav`, the
/// space query, the put sequence, the collections, the error map, and
/// the transport rules of 8.11.
final class WebDAVTests: XCTestCase {

    private let nextcloud = WebDAVServer(
        address: URL(string: "https://cloud.example.com/remote.php/dav/files/alice")!,
        username: "alice")

    private let apache = WebDAVServer(
        address: URL(string: "https://dav.example.com/dav")!, username: "alice")

    // MARK: - The two answer shapes, per test 1

    /// Nextcloud, which is SabreDAV. It names the DAV namespace `d`,
    /// adds namespaces of its own, and answers a second `propstat`
    /// with the properties it has not got.
    private func nextcloudBody() -> Data {
        Data(
            """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" \
            xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
              <d:response>
                <d:href>/remote.php/dav/files/alice/Empo/</d:href>
                <d:propstat>
                  <d:prop>
                    <d:resourcetype><d:collection/></d:resourcetype>
                    <d:getlastmodified>Thu, 27 Aug 2026 10:11:12 GMT</d:getlastmodified>
                  </d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
                <d:propstat>
                  <d:prop><d:getcontentlength/></d:prop>
                  <d:status>HTTP/1.1 404 Not Found</d:status>
                </d:propstat>
              </d:response>
              <d:response>
                <d:href>/remote.php/dav/files/alice/Empo/format.json</d:href>
                <d:propstat>
                  <d:prop>
                    <d:resourcetype/>
                    <d:getcontentlength>128</d:getcontentlength>
                    <d:getlastmodified>Thu, 27 Aug 2026 10:12:00 GMT</d:getlastmodified>
                  </d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """.utf8)
    }

    /// Apache `mod_dav`. It names the DAV namespace `D`, names the
    /// properties with a second prefix of its own, and answers a
    /// whole URL in the `href`.
    private func apacheBody() -> Data {
        Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
            <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
            <D:href>https://dav.example.com/dav/Empo/</D:href>
            <D:propstat><D:prop>
            <lp1:resourcetype><D:collection/></lp1:resourcetype>
            <lp1:getlastmodified>Thu, 27 Aug 2026 10:11:12 GMT</lp1:getlastmodified>
            </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
            <D:href>https://dav.example.com/dav/Empo/format.json</D:href>
            <D:propstat><D:prop>
            <lp1:resourcetype/>
            <lp1:getcontentlength>128</lp1:getcontentlength>
            <lp1:getlastmodified>Thu, 27 Aug 2026 10:12:00 GMT</lp1:getlastmodified>
            </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            </D:multistatus>
            """.utf8)
    }

    func testItReadsTheNextcloudShape() {
        let entries = WebDAV.entries(fromBody: nextcloudBody())
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isCollection)
        XCTAssertFalse(entries[1].isCollection)
        XCTAssertEqual(entries[1].sizeBytes, 128)
        XCTAssertNotNil(entries[1].modifiedAt)

        let objects = nextcloud.objects(fromEntries: entries)
        XCTAssertEqual(objects.map(\.path), ["Empo/format.json"])
        XCTAssertEqual(objects.first?.sizeBytes, 128)
    }

    func testItReadsTheApacheShapeTheSameWay() {
        let entries = WebDAV.entries(fromBody: apacheBody())
        XCTAssertEqual(entries.count, 2)
        // A second prefix on the property names changes nothing.
        XCTAssertTrue(entries[0].isCollection)
        XCTAssertEqual(entries[1].sizeBytes, 128)

        // The href is a whole URL here and a path on Nextcloud. Both
        // lead to the same provider path of 8.1.
        let objects = apache.objects(fromEntries: entries)
        XCTAssertEqual(objects.map(\.path), ["Empo/format.json"])
    }

    func testAPropertyTheServerHasNotGotIsNotRead() {
        // Nextcloud answers `getcontentlength` in a 404 `propstat`
        // for a collection. A reader that took it would name a size
        // the server said it has not got.
        let entries = WebDAV.entries(fromBody: nextcloudBody())
        XCTAssertEqual(entries[0].sizeBytes, 0)
        XCTAssertEqual(WebDAV.status(ofLine: "HTTP/1.1 404 Not Found"), 404)
    }

    func testTheCollectionsOfAnAnswerLeaveOutTheOneTheWalkAsked() {
        let entries = WebDAV.entries(fromBody: nextcloudBody())
        XCTAssertEqual(nextcloud.collections(fromEntries: entries, under: "Empo"), [])
    }

    func testAStagedUploadIsNotAnObject() {
        let body = Data(
            """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/remote.php/dav/files/alice/Empo/.empo-partial-format.json</d:href>
                <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>4</d:getcontentlength>\
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
              </d:response>
            </d:multistatus>
            """.utf8)
        let objects = nextcloud.objects(fromEntries: WebDAV.entries(fromBody: body))
        XCTAssertTrue(objects.isEmpty)
    }

    // MARK: - The space query of RFC 4331, per tests 2 and 3

    private func quotaBody(available: String?, used: String?) -> Data {
        var properties = ""
        if let available {
            properties += "<d:quota-available-bytes>\(available)</d:quota-available-bytes>"
        }
        if let used {
            properties += "<d:quota-used-bytes>\(used)</d:quota-used-bytes>"
        }
        var missing = ""
        if available == nil {
            missing += "<d:quota-available-bytes/>"
        }
        if used == nil {
            missing += "<d:quota-used-bytes/>"
        }
        return Data(
            """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/remote.php/dav/files/alice/</d:href>
                <d:propstat><d:prop>\(properties)</d:prop>\
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
                <d:propstat><d:prop>\(missing)</d:prop>\
            <d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
              </d:response>
            </d:multistatus>
            """.utf8)
    }

    func testAServerThatAnswersRFC4331SetsTheFlagTrue() {
        let reading = WebDAV.quota(fromBody: quotaBody(available: "600", used: "400"))
        XCTAssertEqual(reading, QuotaReading(usedBytes: 400, limitBytes: 1000))
        // The add-time check of 8.7 is what sets the flag, per 9.7.
        let result = PermissionCheckResult(steps: [], quota: reading)
        XCTAssertTrue(result.canQueryQuota)
        XCTAssertTrue(WebDAV.capabilities(answersQuota: result.canQueryQuota).canQueryQuota)
    }

    func testAServerThatOmitsThePropertiesSetsTheFlagFalseAndStillPasses() {
        let reading = WebDAV.quota(fromBody: quotaBody(available: nil, used: nil))
        XCTAssertNil(reading)
        XCTAssertFalse(WebDAV.capabilities(answersQuota: false).canQueryQuota)

        // The free-space step skips, and the add still goes through,
        // per 9.7.
        let result = PermissionCheckResult(
            steps: [
                PermissionCheckStepResult(step: .write, outcome: .passed),
                PermissionCheckStepResult(step: .list, outcome: .passed),
                PermissionCheckStepResult(step: .delete, outcome: .passed),
                PermissionCheckStepResult(step: .freeSpace, outcome: .skipped),
            ],
            quota: nil)
        XCTAssertTrue(result.allowsAdd)
        XCTAssertFalse(result.canQueryQuota)
    }

    func testAServerThatRefusesTheCallAnswersNoSpaceQueryAndNoError() {
        // RFC 4918 asks for a 207 that names the missing property.
        // A server that refuses the method says the same thing.
        XCTAssertTrue(WebDAV.hasNoSpaceQuery(status: 405))
        XCTAssertTrue(WebDAV.hasNoSpaceQuery(status: 501))
        XCTAssertFalse(WebDAV.hasNoSpaceQuery(status: 403))
    }

    func testAShareWithNoLimitStatesAUseAndNoLimit() {
        // Nextcloud writes a negative number for a share with no
        // limit. It still reports a use.
        let reading = WebDAV.quota(fromBody: quotaBody(available: "-3", used: "400"))
        XCTAssertEqual(reading, QuotaReading(usedBytes: 400, limitBytes: nil))
        XCTAssertNil(reading?.freeBytes)
    }

    func testATargetThatStopsAnsweringFallsBackWithNoError() {
        // 13.6: a target that answered once and later stops answering
        // shows the bytes-written line, with no error.
        let capabilities = WebDAV.capabilities(answersQuota: true)
        XCTAssertTrue(capabilities.canQueryQuota)

        let today = WebDAV.quota(fromBody: quotaBody(available: nil, used: nil))
        XCTAssertNil(today)
        // Nothing throws, and the run keeps its room check off.
        XCTAssertNil(QuotaCheck.shortfall(pendingBytes: 999, reading: today, capBytes: nil))
        XCTAssertEqual(
            TargetCapabilities.noSpaceQueryLine, "This service does not report free space.")
    }

    // MARK: - The error map, per test 4

    func testEachWebDAVStatusMapsToItsErrorKind() {
        XCTAssertEqual(WebDAV.error(status: 401), .authExpired)
        XCTAssertEqual(WebDAV.error(status: 401).effect, .needsSignIn)

        XCTAssertEqual(WebDAV.error(status: 403), .permissionDenied)
        // A re-sign-in does not add a right, per 8.4.
        XCTAssertEqual(WebDAV.error(status: 403).effect, .blocked)

        XCTAssertEqual(WebDAV.error(status: 404), .notFound)
        XCTAssertEqual(WebDAV.error(status: 404).effect, .dropFromCache)

        XCTAssertEqual(WebDAV.error(status: 507), .outOfSpace)
        XCTAssertEqual(WebDAV.error(status: 507).effect, .runPruneLadder)

        guard case .rejected(let message) = WebDAV.error(status: 423) else {
            return XCTFail("423 is a refusal the user has to read")
        }
        XCTAssertEqual(message, "the server answered 423")
    }

    func testALockedPathCarriesTheServersOwnWords() {
        let body = Data(
            """
            <?xml version="1.0"?>
            <d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
            <s:message>The resource is locked</s:message></d:error>
            """.utf8)
        let error = WebDAV.error(status: 423, body: body)
        XCTAssertEqual(error, .rejected(message: "the server answered 423: The resource is locked"))
        XCTAssertTrue(error.effect.stopsTheRun)
    }

    func testAServerThatAsksForAWaitKeepsTheRun() {
        let error = WebDAV.error(status: 503, retryAfterHeader: "30")
        XCTAssertEqual(error, .throttled(retryAfter: 30))
        XCTAssertEqual(error.effect, .waitAndKeepRun(seconds: 30))

        // A server that states no time gets the truncated backoff.
        XCTAssertEqual(WebDAV.error(status: 429, attempt: 3), .throttled(retryAfter: 4))
        XCTAssertEqual(WebDAV.backoffSeconds(attempt: 99), WebDAV.backoffCeilingSeconds)
    }

    func testARetryAfterDateReadsAsAWait() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(45)
        let header = WebDAVTests.httpDate(later)
        XCTAssertEqual(
            WebDAV.retryAfterSeconds(header, now: now), 45, accuracy: 1)
        // A date that has already passed is no wait at all, so the
        // backoff decides.
        XCTAssertEqual(
            WebDAV.retryAfterSeconds(WebDAVTests.httpDate(now.addingTimeInterval(-60)), now: now),
            WebDAV.backoffSeconds(attempt: 1))
    }

    func testAServerThatIsUpButUnwellRetriesOnTheNextPass() {
        XCTAssertEqual(WebDAV.error(status: 500), .offline)
        XCTAssertEqual(WebDAV.error(status: 500).effect, .retryOnNextPass)
    }

    // MARK: - The temp name and the MOVE, per tests 5 and 6

    func testThePutStagesUnderATempNameAndCommitsWithAMove() {
        let path = "Empo/devices/n1/blobs/ab/abcdef"
        let steps = WebDAV.putSteps(path: path)
        XCTAssertEqual(
            steps,
            [
                .stage(path: "Empo/devices/n1/blobs/ab/.empo-partial-abcdef"),
                .commit(from: "Empo/devices/n1/blobs/ab/.empo-partial-abcdef", to: path),
            ])

        // Nothing before the commit names the path, so the path holds
        // the old content until the MOVE answers, per 8.2.
        for step in steps.dropLast() {
            guard case .stage(let staged) = step else { return XCTFail("the first step stages") }
            XCTAssertNotEqual(staged, path)
        }
        // The temp name is a sibling, so the MOVE stays inside one
        // collection and the server renames.
        XCTAssertEqual(
            WebDAV.collectionPath(ofPath: WebDAV.temporaryPath(for: path)),
            WebDAV.collectionPath(ofPath: path))
    }

    func testAnInterruptedPutStartsAgainUnderTheSameTempName() {
        // The RFC states no resumable mode, per 9.5. So the second
        // attempt writes over the first one's bytes and the path is
        // untouched either way.
        let path = "Empo/format.json"
        XCTAssertEqual(WebDAV.putSteps(path: path), WebDAV.putSteps(path: path))
        XCTAssertEqual(WebDAV.temporaryPath(for: path), "Empo/.empo-partial-format.json")
        XCTAssertTrue(WebDAV.isTemporaryPath(WebDAV.temporaryPath(for: path)))
        XCTAssertFalse(WebDAV.isTemporaryPath(path))
    }

    // MARK: - The collections, per test 8

    func testItMakesEveryCollectionOnTheWayShallowestFirst() {
        XCTAssertEqual(
            WebDAV.ancestorCollections(ofPath: "empo/Empo/devices/n1/format.json"),
            ["empo", "empo/Empo", "empo/Empo/devices", "empo/Empo/devices/n1"])
        // A file at the top needs no collection at all.
        XCTAssertEqual(WebDAV.ancestorCollections(ofPath: "format.json"), [])
    }

    func testMakingACollectionTwiceIsNotAFailure() {
        // RFC 4918 answers 405 when the collection is already there.
        XCTAssertTrue(WebDAV.collectionIsAlreadyThere(status: 405))
        XCTAssertFalse(WebDAV.collectionIsAlreadyThere(status: 201))
        // A parent that is missing is what a 409 says, and some
        // servers say 404 instead.
        XCTAssertTrue(WebDAV.needsACollection(status: 409))
        XCTAssertTrue(WebDAV.needsACollection(status: 404))
        XCTAssertFalse(WebDAV.needsACollection(status: 403))
    }

    func testAWalkStartsAtTheCollectionThatHoldsThePrefix() {
        XCTAssertEqual(WebDAV.collectionPath(ofPrefix: "Empo/devices/n1/blobs/"), "Empo/devices/n1/blobs")
        XCTAssertEqual(WebDAV.collectionPath(ofPrefix: "Empo/format.json"), "Empo")
        XCTAssertEqual(WebDAV.collectionPath(ofPrefix: "format.json"), "")
    }

    // MARK: - Transport, per test 7

    func testAPlainAddressIsRefusedBeforeAnyRequest() {
        let plain = WebDAVServer(
            address: URL(string: "http://cloud.example.com/dav")!, username: "alice")
        XCTAssertEqual(
            plain.refusal, .rejected(message: TransportSecurity.plainAddressMessage))
        XCTAssertNil(nextcloud.refusal)
    }

    func testAServerWithNoUserNameIsRefused() {
        let nameless = WebDAVServer(
            address: URL(string: "https://cloud.example.com/dav")!, username: " ")
        XCTAssertEqual(nameless.refusal, .rejected(message: "Type the user name of the server."))
    }

    // MARK: - The address

    func testItBuildsTheAddressOfOnePath() {
        XCTAssertEqual(
            nextcloud.url(path: "Empo/format.json")?.absoluteString,
            "https://cloud.example.com/remote.php/dav/files/alice/Empo/format.json")
        // An empty path is the root of the target, which the space
        // query asks about.
        XCTAssertEqual(
            nextcloud.url()?.absoluteString,
            "https://cloud.example.com/remote.php/dav/files/alice")
    }

    func testItEncodesAPathTheServerAnsweredAndReadsItBack() {
        let path = "Empo/My Saves/a+b.json"
        let encoded = nextcloud.absolutePath(path)
        XCTAssertTrue(encoded.hasSuffix("/Empo/My%20Saves/a+b.json"))
        XCTAssertEqual(nextcloud.relativePath(ofHref: encoded), path)
    }

    func testAnHrefOfAnotherServerIsNotAPathOfThisOne() {
        XCTAssertNil(nextcloud.relativePath(ofHref: "/somewhere/else/format.json"))
    }

    // MARK: - The flags of 8.3 and the add form of 13.7

    func testTheCapabilityFlagsReadAsSectionNineStates() {
        let flags = WebDAV.capabilities(answersQuota: true)
        XCTAssertTrue(flags.reportsObjectAge)
        XCTAssertTrue(flags.supportsBackgroundTransfer)
        XCTAssertFalse(flags.foldsCase)
        // 9.5: the file limit is whatever the server allows, and the
        // server states no number.
        XCTAssertNil(flags.maxFileSize)
        XCTAssertNil(flags.rejection(forFileOfSize: .max))
    }

    func testTheAddFormCarriesTheStorageWarningBesideTheAddress() {
        let names = WebDAV.addFormFields.map(\.name)
        XCTAssertEqual(names, ["label", "address", "root", "username", "password"])
        XCTAssertEqual(
            WebDAV.addFormFields.first { $0.name == "address" }?.note,
            TransportSecurity.storageWarning)
        XCTAssertEqual(
            WebDAV.addFormFields.first { $0.name == "password" }?.kind, .secret)
        // The folder is the one field the user may leave empty.
        XCTAssertEqual(WebDAV.addFormFields.filter { !$0.isRequired }.map(\.name), ["root"])
    }

    func testBasicAuthCarriesTheUserAndThePassword() {
        let connection = WebDAVConnection(server: nextcloud, password: "app-password")
        XCTAssertEqual(
            connection.authorizationHeader,
            "Basic " + Data("alice:app-password".utf8).base64EncodedString())
        XCTAssertEqual(connection.accountHint, "alice at cloud.example.com")
    }

    func testTheKeychainRecordCarriesTheServerAndThePassword() throws {
        var server = nextcloud
        server.answersQuota = true
        let connection = WebDAVConnection(server: server, password: "app-password")
        let read = try WebDAVConnection.decode(json: try connection.jsonData())
        XCTAssertEqual(read, connection)
        // 9.7 makes the space query a fact about the server, so it
        // travels with it.
        XCTAssertTrue(read.server.answersQuota)
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

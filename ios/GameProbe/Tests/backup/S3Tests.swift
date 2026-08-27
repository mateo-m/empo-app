import Foundation
import XCTest

@testable import GameProbe

/// The S3-compatible rules of SPEC 9.4.
///
/// The bucket needs an access key, so these checks cover the parts
/// that do not: the error map, the upload plan, the paging, the
/// commit body, the transport rules of 8.11, and the capability
/// flags. `S3SigV4Tests` covers the signature.
final class S3Tests: XCTestCase {

    private let gibibyte: Int64 = 1024 * 1024 * 1024

    private func errorBody(code: String, message: String) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>\(code)</Code><Message>\(message)</Message>\
            <RequestId>656c76696e</RequestId></Error>
            """.utf8)
    }

    private func failure(code: String, message: String = "") -> S3.Failure {
        S3.failure(inBody: errorBody(code: code, message: message))
    }

    // MARK: - 3. The error map, per 8.4

    func testAWrongSignatureBlocksTheTarget() {
        let error = S3.error(
            status: 403,
            failure: failure(
                code: "SignatureDoesNotMatch",
                message: "The request signature we calculated does not match."))
        XCTAssertEqual(error, .permissionDenied)
        // A re-sign-in does not add a right, per 8.4.
        XCTAssertEqual(error.effect, .blocked)
    }

    func testADeniedCallBlocksTheTarget() {
        let error = S3.error(
            status: 403, failure: failure(code: "AccessDenied", message: "Access Denied"))
        XCTAssertEqual(error, .permissionDenied)
        XCTAssertEqual(error.effect, .blocked)
    }

    func testAKeyTheServiceDoesNotKnowAsksForANewOne() {
        let error = S3.error(
            status: 403,
            failure: failure(
                code: "InvalidAccessKeyId", message: "The access key does not exist."))
        XCTAssertEqual(error, .authExpired)
        XCTAssertEqual(error.effect, .needsSignIn)
    }

    func testAMissingKeyDropsItFromTheCache() {
        let error = S3.error(
            status: 404,
            failure: failure(code: "NoSuchKey", message: "The specified key does not exist."))
        XCTAssertEqual(error, .notFound)
        XCTAssertEqual(error.effect, .dropFromCache)
    }

    func testSlowDownThrottles() {
        let error = S3.error(
            status: 503,
            failure: failure(code: "SlowDown", message: "Please reduce your request rate."),
            retryAfterHeader: "9")
        XCTAssertEqual(error, .throttled(retryAfter: 9))
        XCTAssertEqual(error.effect, .waitAndKeepRun(seconds: 9))
    }

    func testAThrottleWithNoStatedTimeTakesTheTruncatedBackoff() {
        let error = S3.error(
            status: 503, failure: failure(code: "SlowDown"), attempt: 4)
        XCTAssertEqual(error, .throttled(retryAfter: S3.backoffSeconds(attempt: 4)))
        XCTAssertEqual(S3.backoffSeconds(attempt: 1), 1)
        XCTAssertEqual(S3.backoffSeconds(attempt: 4), 8)
        XCTAssertEqual(S3.backoffSeconds(attempt: 40), S3.backoffCeilingSeconds)
    }

    func testAFullBucketRunsThePruneLadder() {
        let error = S3.error(
            status: 403,
            failure: failure(code: "QuotaExceeded", message: "The bucket is over its quota."))
        XCTAssertEqual(error, .outOfSpace)
        XCTAssertEqual(error.effect, .runPruneLadder)
    }

    func testAServiceWithNoRoomLeftRunsThePruneLadder() {
        // MinIO answers 507 with no body Empo can read.
        XCTAssertEqual(S3.error(status: 507), .outOfSpace)
        XCTAssertEqual(
            S3.error(status: 500, failure: failure(code: "StorageCapExceeded")), .outOfSpace)
    }

    func testAMissingBucketIsPermanentAndNotAMissingKey() {
        let error = S3.error(
            status: 404,
            failure: failure(
                code: "NoSuchBucket", message: "The specified bucket does not exist."))
        XCTAssertEqual(
            error, .rejected(message: "the bucket answered 404: The specified bucket does not exist.")
        )
        XCTAssertEqual(
            error.effect,
            .stopAndShow(message: "the bucket answered 404: The specified bucket does not exist."))
    }

    func testAServerErrorRetriesOnTheNextPass() {
        XCTAssertEqual(S3.error(status: 500), .offline)
        XCTAssertEqual(S3.error(status: 502), .offline)
    }

    func testAnUnknownCodeReachesTheUserWordForWord() {
        let error = S3.error(
            status: 400,
            failure: failure(
                code: "EntityTooLarge", message: "Your proposed upload exceeds the maximum."))
        XCTAssertEqual(
            error,
            .rejected(message: "the bucket answered 400: Your proposed upload exceeds the maximum."))
    }

    func testAFailureWithNoBodyStillNamesTheStatus() {
        XCTAssertEqual(
            S3.error(status: 418), .rejected(message: "the bucket answered 418"))
    }

    // MARK: - 4. The upload plan of 9.4

    func testAFileUnderFiveGibibytesTakesOnePutObject() {
        XCTAssertEqual(S3.uploadPlan(forFileOfSize: 1), .single)
        XCTAssertEqual(S3.uploadPlan(forFileOfSize: S3.singleUploadLimitBytes), .single)
        XCTAssertEqual(S3.singleUploadLimitBytes, 5 * gibibyte)
    }

    func testAFileOverFiveGibibytesTakesAMultipartUpload() {
        let plan = S3.uploadPlan(forFileOfSize: S3.singleUploadLimitBytes + 1)
        guard case .multipart(let parts) = plan else {
            return XCTFail("a file over the single limit takes a multipart upload")
        }
        XCTAssertEqual(parts.first?.number, 1)
        XCTAssertEqual(parts.first?.offset, 0)
        XCTAssertEqual(parts.last?.endOffset, S3.singleUploadLimitBytes + 1)
        // Every part but the last holds the same count.
        XCTAssertEqual(parts.dropLast().map(\.length).uniqueCount, 1)
    }

    func testADeviceCheckCanLowerTheThresholdAndStillTakeTheMultipartPath() {
        // The device check of ticket 011 cannot write a 5 GiB file on
        // a phone, so it lowers the two numbers behind a debug flag.
        let plan = S3.uploadPlan(
            forFileOfSize: 12 * 1024 * 1024, singleLimit: 8 * 1024 * 1024,
            base: S3.minimumPartBytes)
        guard case .multipart(let parts) = plan else {
            return XCTFail("a lowered threshold takes the multipart path")
        }
        XCTAssertEqual(parts.count, 3)
        let mebibyte: Int64 = 1024 * 1024
        let expected: [Int64] = [5 * mebibyte, 5 * mebibyte, 2 * mebibyte]
        XCTAssertEqual(parts.map(\.length), expected)
    }

    func testThePartSizeGrowsSoTenThousandPartsCarryTheFile() {
        let huge = S3.defaultPartBytes * Int64(S3.maximumPartCount) * 4
        let size = S3.partSize(forFileOfSize: huge)
        XCTAssertGreaterThan(size, S3.defaultPartBytes)
        XCTAssertLessThanOrEqual(
            (huge + size - 1) / size, Int64(S3.maximumPartCount))
        XCTAssertEqual(size % S3.minimumPartBytes, 0)
    }

    func testThePartSizeNeverPassesTheFiveGibibyteLimit() {
        XCTAssertEqual(
            S3.partSize(forFileOfSize: S3.awsMaxFileSizeBytes), S3.singleUploadLimitBytes)
    }

    // MARK: - 5. A permanent failure aborts the multipart upload

    func testAPermanentFailureAbortsTheUploadAndAThrottleDoesNot() {
        // Parts cost money, per 9.4, so a run that will never finish
        // takes its parts with it.
        XCTAssertTrue(S3.abortsMultipart(after: .permissionDenied))
        XCTAssertTrue(S3.abortsMultipart(after: .authExpired))
        XCTAssertTrue(S3.abortsMultipart(after: .rejected(message: "no")))

        // These carry on from the same id on the next pass.
        XCTAssertFalse(S3.abortsMultipart(after: .throttled(retryAfter: 2)))
        XCTAssertFalse(S3.abortsMultipart(after: .offline))
        XCTAssertFalse(S3.abortsMultipart(after: .outOfSpace))
    }

    func testAnUploadTheServiceDroppedStartsAgainUnderANewId() {
        XCTAssertTrue(
            S3.isUploadGone(status: 404, failure: failure(code: "NoSuchUpload")))
        XCTAssertTrue(S3.isUploadGone(status: 404, failure: S3.Failure(code: "", message: "")))
        XCTAssertFalse(
            S3.isUploadGone(status: 403, failure: failure(code: "AccessDenied")))
    }

    // MARK: - 6. ListObjectsV2 paging

    private func listBody(keys: [(String, Int64)], nextToken: String?) -> Data {
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Name>my-saves</Name><Prefix>Empo/</Prefix><KeyCount>\(keys.count)</KeyCount>
            <MaxKeys>1000</MaxKeys><IsTruncated>\(nextToken == nil ? "false" : "true")</IsTruncated>
            """
        if let nextToken {
            xml += "<NextContinuationToken>\(nextToken)</NextContinuationToken>"
        }
        for (key, size) in keys {
            xml += """
                <Contents><Key>\(key)</Key><LastModified>2026-08-27T10:00:00.000Z</LastModified>\
                <ETag>&quot;abc&quot;</ETag><Size>\(size)</Size>\
                <StorageClass>STANDARD</StorageClass></Contents>
                """
        }
        xml += "</ListBucketResult>"
        return Data(xml.utf8)
    }

    func testAPageCarriesItsObjectsAndItsContinuationToken() {
        let page = S3.page(
            fromBody: listBody(keys: [("Empo/a", 10), ("Empo/b", 20)], nextToken: "tok/1+2="))
        XCTAssertEqual(page?.objects.count, 2)
        XCTAssertEqual(page?.objects.first?.key, "Empo/a")
        XCTAssertEqual(page?.objects.first?.sizeBytes, 10)
        XCTAssertNotNil(page?.objects.first?.lastModified)
        XCTAssertEqual(page?.nextContinuationToken, "tok/1+2=")
        XCTAssertEqual(page?.hasMore, true)
    }

    func testTheLastPageCarriesNoToken() {
        let page = S3.page(fromBody: listBody(keys: [("Empo/a", 1)], nextToken: nil))
        XCTAssertNil(page?.nextContinuationToken)
        XCTAssertEqual(page?.hasMore, false)
    }

    func testEveryPageOfAListReturnsEveryObjectInOrder() {
        let first = S3.page(
            fromBody: listBody(keys: [("Empo/c", 3), ("Empo/a", 1)], nextToken: "next"))
        let second = S3.page(fromBody: listBody(keys: [("Empo/b", 2)], nextToken: nil))
        let objects = S3.objects(fromPages: [first, second].compactMap { $0 })

        XCTAssertEqual(objects.map(\.path), ["Empo/a", "Empo/b", "Empo/c"])
        XCTAssertEqual(objects.map(\.sizeBytes), [1, 2, 3])
    }

    func testAnEmptyBucketAnswersAnEmptyPageAndNotAFailure() {
        let page = S3.page(fromBody: listBody(keys: [], nextToken: nil))
        XCTAssertEqual(page?.objects.isEmpty, true)
        XCTAssertNil(S3.page(fromBody: Data("not xml".utf8)))
    }

    func testTheListQueryNamesTheVersionThePrefixAndTheToken() {
        let query = S3.listQuery(prefix: "Empo/", continuationToken: "tok")
        XCTAssertEqual(
            S3SigV4.canonicalQuery(query),
            "continuation-token=tok&list-type=2&max-keys=1000&prefix=Empo%2F")
        XCTAssertFalse(
            S3SigV4.canonicalQuery(S3.listQuery(prefix: "")).contains("prefix"))
    }

    // MARK: - The multipart calls

    func testTheUploadIdComesOutOfTheCreateAnswer() {
        let body = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <InitiateMultipartUploadResult><Bucket>my-saves</Bucket><Key>Empo/a</Key>\
            <UploadId>VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3</UploadId>\
            </InitiateMultipartUploadResult>
            """.utf8)
        XCTAssertEqual(S3.uploadId(fromBody: body), "VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3")
        XCTAssertNil(S3.uploadId(fromBody: Data()))
    }

    func testAResumedRunReadsThePartsTheServiceAlreadyHolds() {
        let body = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListPartsResult><Bucket>my-saves</Bucket><Key>Empo/a</Key>\
            <Part><PartNumber>2</PartNumber><ETag>&quot;two&quot;</ETag><Size>10</Size></Part>\
            <Part><PartNumber>1</PartNumber><ETag>&quot;one&quot;</ETag><Size>10</Size></Part>\
            </ListPartsResult>
            """.utf8)
        let parts = S3.completedParts(fromBody: body)
        XCTAssertEqual(parts.map(\.number), [1, 2])
        XCTAssertEqual(parts.map(\.eTag), ["\"one\"", "\"two\""])
    }

    func testTheCommitBodyListsThePartsInOrder() {
        let body = S3.completeBody(parts: [
            S3.CompletedPart(number: 2, eTag: "\"two\""),
            S3.CompletedPart(number: 1, eTag: "\"one\""),
        ])
        XCTAssertEqual(
            String(data: body, encoding: .utf8),
            "<CompleteMultipartUpload>"
                + "<Part><PartNumber>1</PartNumber><ETag>&quot;one&quot;</ETag></Part>"
                + "<Part><PartNumber>2</PartNumber><ETag>&quot;two&quot;</ETag></Part>"
                + "</CompleteMultipartUpload>")
    }

    func testTheUploadsOfOneKeyComeOutOfTheListAnswer() {
        let body = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListMultipartUploadsResult><Bucket>my-saves</Bucket>\
            <Upload><Key>Empo/a</Key><UploadId>one</UploadId></Upload>\
            <Upload><Key>Empo/b</Key><UploadId>two</UploadId></Upload>\
            <Upload><Key>Empo/a</Key><UploadId>three</UploadId></Upload>\
            </ListMultipartUploadsResult>
            """.utf8)
        XCTAssertEqual(S3.uploadIds(fromBody: body, key: "Empo/a"), ["one", "three"])
        XCTAssertEqual(S3.uploadIds(fromBody: body, key: "Empo/z"), [])
    }

    func testEachMultipartCallNamesTheUploadItWorksOn() {
        XCTAssertEqual(S3SigV4.canonicalQuery(S3.uploadsQuery()), "uploads=")
        XCTAssertEqual(
            S3SigV4.canonicalQuery(S3.uploadsQuery(prefix: "Empo/a")), "prefix=Empo%2Fa&uploads=")
        XCTAssertEqual(
            S3SigV4.canonicalQuery(S3.partQuery(number: 7, uploadId: "id/1")),
            "partNumber=7&uploadId=id%2F1")
        XCTAssertEqual(
            S3SigV4.canonicalQuery(S3.uploadQuery(uploadId: "id/1")), "uploadId=id%2F1")
    }

    // MARK: - The record that outlives the process

    func testARecordCarriesOnWhileTheFileAndTheWeekHold() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let record = S3MultipartUpload(
            uploadId: "id", key: "Empo/a", fileSize: 100, partSize: 50, startedAt: started)

        XCTAssertTrue(record.isUsable(at: started.addingTimeInterval(60), forFileOfSize: 100))
        // A file of another size at the same key is another upload.
        XCTAssertFalse(record.isUsable(at: started, forFileOfSize: 101))
        XCTAssertFalse(
            record.isUsable(
                at: started.addingTimeInterval(S3MultipartUpload.lifetime + 1),
                forFileOfSize: 100))
    }

    func testTheServiceDecidesWhichPartsARecordHolds() {
        let record = S3MultipartUpload(
            uploadId: "id", key: "Empo/a", fileSize: 100, partSize: 50,
            parts: [S3.CompletedPart(number: 1, eTag: "\"stale\"")],
            startedAt: Date(timeIntervalSince1970: 0))

        let taken = record.adding(S3.CompletedPart(number: 2, eTag: "\"two\""))
        XCTAssertEqual(taken.parts.map(\.number), [1, 2])
        XCTAssertEqual(taken.eTag(ofPart: 2), "\"two\"")

        // A part the record names and the service does not hold goes
        // up again.
        let matched = taken.matching([S3.CompletedPart(number: 2, eTag: "\"two\"")])
        XCTAssertEqual(matched.parts.map(\.number), [2])
        XCTAssertNil(matched.eTag(ofPart: 1))
    }

    // MARK: - 7. The transport rules of 8.11

    func testAPlainAddressIsRefusedBeforeAnyRequest() {
        let bucket = S3Bucket(
            address: URL(string: "http://minio.example.com")!, region: "us-east-1",
            name: "my-saves", usesPathStyle: true)
        XCTAssertEqual(
            bucket.refusal, .rejected(message: TransportSecurity.plainAddressMessage))
        XCTAssertEqual(bucket.refusal?.effect.stopsTheRun, true)
    }

    func testAnHTTPSAddressWithABucketAndARegionPasses() {
        let bucket = S3Bucket(
            address: URL(string: "https://minio.example.com")!, region: "us-east-1",
            name: "my-saves", usesPathStyle: true)
        XCTAssertNil(bucket.refusal)
    }

    func testABucketWithNoNameOrNoRegionIsRefused() {
        let address = URL(string: "https://minio.example.com")!
        XCTAssertNotNil(
            S3Bucket(address: address, region: "us-east-1", name: " ", usesPathStyle: true)
                .refusal)
        XCTAssertNotNil(
            S3Bucket(address: address, region: "", name: "my-saves", usesPathStyle: true).refusal)
    }

    func testASelfSignedCertificateFailsWithTheSystemTrustLine() {
        // -1202 is the code URL loading answers for a certificate the
        // device does not trust.
        let error = TransportSecurity.certificateError(
            urlErrorCode: -1202, description: "The certificate for this server is invalid.")
        XCTAssertEqual(
            error,
            .rejected(
                message: "The certificate for this server is invalid. "
                    + TransportSecurity.systemTrustMessage))
        XCTAssertEqual(error?.effect.stopsTheRun, true)
        XCTAssertTrue(TransportSecurity.systemTrustMessage.contains("self-signed"))
    }

    func testAFailureThatIsNotACertificateKeepsItsOwnKind() {
        XCTAssertNil(TransportSecurity.certificateError(urlErrorCode: -1009, description: "offline"))
        XCTAssertFalse(TransportSecurity.isCertificateFailure(urlErrorCode: -1009))
        XCTAssertTrue(TransportSecurity.isCertificateFailure(urlErrorCode: -1200))
    }

    // MARK: - 8. The capability flags of 8.3 and the table of 9.7

    func testTheCapabilityFlagsReadAsSectionNineStates() {
        let flags = S3.capabilities
        // 9.7: S3-compatible storage has no free-space call.
        XCTAssertFalse(flags.canQueryQuota)
        XCTAssertTrue(flags.reportsObjectAge)
        XCTAssertTrue(flags.supportsBackgroundTransfer)
        XCTAssertFalse(flags.foldsCase)
        XCTAssertEqual(flags.maxFileSize, S3.r2MaxFileSizeBytes)
    }

    func testTheTwoFileLimitsOfNineFourReadAsStated() {
        // 48.8 TiB on AWS: 10,000 parts of 5 GiB.
        XCTAssertEqual(S3.awsMaxFileSizeBytes, 10_000 * 5 * gibibyte)
        XCTAssertEqual(
            Double(S3.awsMaxFileSizeBytes) / Double(1024 * gibibyte), 48.828125, accuracy: 0.001)
        // 4.995 TiB on R2.
        XCTAssertEqual(
            Double(S3.r2MaxFileSizeBytes) / Double(1024 * gibibyte), 4.995, accuracy: 0.001)
    }

    func testAFileOverTheLimitIsRefusedAndNotCalledOutOfSpace() {
        let rejection = S3.capabilities.rejection(forFileOfSize: S3.maxFileSizeBytes + 1)
        guard case .rejected = rejection else {
            return XCTFail("a file over the limit is a permanent refusal")
        }
        XCTAssertNil(S3.capabilities.rejection(forFileOfSize: 1))
    }

    // MARK: - The bucket URLs

    func testAPathStyleBucketPutsTheNameInThePath() {
        let bucket = S3Bucket(
            address: URL(string: "https://minio.example.com:9000")!, region: "us-east-1",
            name: "my-saves", usesPathStyle: true)
        XCTAssertEqual(bucket.host, "minio.example.com")
        XCTAssertEqual(bucket.canonicalPath(key: "Empo/format.json"), "/my-saves/Empo/format.json")
        XCTAssertEqual(
            bucket.url(key: "Empo/format.json")?.absoluteString,
            "https://minio.example.com:9000/my-saves/Empo/format.json")
    }

    func testAHostStyleBucketPutsTheNameInTheHost() {
        let bucket = S3Bucket(
            address: URL(string: "https://s3.eu-west-1.amazonaws.com")!, region: "eu-west-1",
            name: "my-saves", usesPathStyle: false)
        XCTAssertEqual(bucket.host, "my-saves.s3.eu-west-1.amazonaws.com")
        XCTAssertEqual(bucket.canonicalPath(key: "Empo/format.json"), "/Empo/format.json")
    }

    func testAnAddressWithItsOwnPathKeepsIt() {
        let bucket = S3Bucket(
            address: URL(string: "https://example.com/s3/")!, region: "us-east-1",
            name: "my-saves", usesPathStyle: true)
        XCTAssertEqual(bucket.canonicalPath(key: "Empo/a"), "/s3/my-saves/Empo/a")
        XCTAssertEqual(bucket.canonicalPath(key: ""), "/s3/my-saves")
    }

    func testAKeyEncodesOnceInTheURL() {
        let bucket = S3Bucket(
            address: URL(string: "https://example.com")!, region: "us-east-1",
            name: "my-saves", usesPathStyle: true)
        XCTAssertEqual(
            bucket.canonicalPath(key: "Empo/a b$c"), "/my-saves/Empo/a%20b%24c")
    }

    func testTheAddFormOffersTheStyleTheHostUses() {
        XCTAssertFalse(
            S3Bucket.prefersPathStyle(address: URL(string: "https://s3.amazonaws.com")!))
        XCTAssertTrue(
            S3Bucket.prefersPathStyle(address: URL(string: "https://minio.example.com")!))
    }

    func testTheAccountHintNamesTheBucketAndTheHostAndNoKey() {
        let connection = S3Connection(
            bucket: S3Bucket(
                address: URL(string: "https://minio.example.com")!, region: "us-east-1",
                name: "my-saves", usesPathStyle: true),
            credentials: S3SigV4.Credentials(
                accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "secret"))
        XCTAssertEqual(connection.accountHint, "my-saves at minio.example.com")
        XCTAssertFalse(connection.accountHint.contains("secret"))
    }

    func testTheConnectionRoundTripsThroughItsJSON() throws {
        let connection = S3Connection(
            bucket: S3Bucket(
                address: URL(string: "https://minio.example.com")!, region: "us-east-1",
                name: "my-saves", usesPathStyle: true),
            credentials: S3SigV4.Credentials(
                accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "secret"))
        XCTAssertEqual(try S3Connection.decode(json: connection.jsonData()), connection)
    }

    // MARK: - The add form of 13.7

    func testTheAddFormCarriesTheStorageWarningBesideTheAddress() {
        let address = S3.addFormFields.first { $0.name == "address" }
        XCTAssertEqual(address?.note, TransportSecurity.storageWarning)
        XCTAssertTrue(TransportSecurity.storageWarning.contains("read your saves"))
        // 5.7 is the rule: no other field carries the line.
        XCTAssertEqual(S3.addFormFields.compactMap(\.note).count, 1)
    }

    func testTheAddFormAsksForTheKeyAsASecretAndForNothingElseHidden() {
        let secrets = S3.addFormFields.filter { $0.kind == .secret }
        XCTAssertEqual(secrets.map(\.name), ["secretAccessKey"])
        XCTAssertEqual(
            S3.addFormFields.map(\.name),
            [
                "label", "address", "bucket", "region", "root", "accessKeyId",
                "secretAccessKey", "usesPathStyle",
            ])
        // The folder and the style are the two the user may leave.
        XCTAssertEqual(
            S3.addFormFields.filter { !$0.isRequired }.map(\.name), ["root", "usesPathStyle"])
    }

    func testTheTargetScreenSaysWhyItShowsNoFreeSpace() {
        // 13.6 shows the bytes Empo wrote, plus this line.
        XCTAssertEqual(
            TargetCapabilities.noSpaceQueryLine, "This service does not report free space.")
    }
}

extension Array where Element: Hashable {
    /// How many different values the array holds.
    fileprivate var uniqueCount: Int { Set(self).count }
}

import Foundation
import XCTest

@testable import GameProbe

/// The signature of SPEC 9.4, against the vectors AWS publishes.
///
/// Empo signs SigV4 by hand, so nothing but these vectors proves the
/// canonical form is right. One wrong space, one wrong sort, or one
/// wrong encoding turns every request into 403
/// `SignatureDoesNotMatch`, and the target blocks itself.
///
/// The four cases are the ones AWS documents:
///
/// - `get-vanilla` of the SigV4 test suite, which uses the service
///   name `service` and not `s3`.
/// - The `GET Object` example of the S3 signing documents.
/// - The `PUT Object` example of the same documents, whose key needs
///   encoding.
/// - The query-string example, which is a presigned URL.
final class S3SigV4Tests: XCTestCase {

    /// The key pair AWS uses in the S3 examples. It is a published
    /// example and it opens nothing.
    private let s3Credentials = S3SigV4.Credentials(
        accessKeyId: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

    /// The key pair of the SigV4 test suite. Its secret differs from
    /// the S3 one by a single character, which is on purpose.
    private let suiteCredentials = S3SigV4.Credentials(
        accessKeyId: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")

    /// 24 May 2013, 00:00:00 UTC, which the S3 examples sign at.
    private var exampleDate: Date {
        var components = DateComponents()
        components.year = 2013
        components.month = 5
        components.day = 24
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    /// 30 August 2015, 12:36:00 UTC, which the test suite signs at.
    private var suiteDate: Date {
        var components = DateComponents()
        components.year = 2015
        components.month = 8
        components.day = 30
        components.hour = 12
        components.minute = 36
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    // MARK: - The two time forms

    func testTheTwoTimeFormsReadAsTheVectorsDo() {
        XCTAssertEqual(S3SigV4.amzDate(exampleDate), "20130524T000000Z")
        XCTAssertEqual(S3SigV4.dateStamp(exampleDate), "20130524")
        XCTAssertEqual(S3SigV4.amzDate(suiteDate), "20150830T123600Z")
        XCTAssertEqual(
            S3SigV4.scope(dateStamp: "20130524", region: "us-east-1"),
            "20130524/us-east-1/s3/aws4_request")
    }

    // MARK: - 1. The test-suite vector

    func testTheSignerReproducesGetVanillaOfTheTestSuite() {
        let signed = S3SigV4.signInHeader(
            method: "GET",
            canonicalPath: "/",
            query: [],
            headers: ["host": "example.amazonaws.com"],
            payloadHash: S3SigV4.emptyPayloadHash,
            credentials: suiteCredentials,
            region: "us-east-1",
            date: suiteDate)

        // `get-vanilla` signs the service name `service`. Empo signs
        // `s3`, so this check drives the four steps by hand with the
        // one field the suite changes.
        let canonical = S3SigV4.canonicalRequest(
            method: "GET",
            canonicalPath: "/",
            canonicalQuery: "",
            headers: [
                "host": "example.amazonaws.com",
                "x-amz-date": "20150830T123600Z",
            ],
            payloadHash: S3SigV4.emptyPayloadHash)
        XCTAssertEqual(canonical.signedNames, "host;x-amz-date")
        XCTAssertEqual(
            canonical.text,
            """
            GET
            /

            host:example.amazonaws.com
            x-amz-date:20150830T123600Z

            host;x-amz-date
            \(S3SigV4.emptyPayloadHash)
            """)

        let toSign = S3SigV4.stringToSign(
            amzDate: "20150830T123600Z",
            scope: "20150830/us-east-1/service/aws4_request",
            canonicalRequest: canonical.text)
        var key = Data("AWS4\(suiteCredentials.secretAccessKey)".utf8)
        for step in ["20150830", "us-east-1", "service", "aws4_request"] {
            key = Self.hmac(key: key, text: step)
        }
        XCTAssertEqual(
            Self.hex(Self.hmac(key: key, text: toSign)),
            "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")

        // The header the signer builds carries the same three parts.
        XCTAssertTrue(signed.headers["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
        XCTAssertEqual(signed.headers["x-amz-date"], "20150830T123600Z")
        XCTAssertEqual(signed.headers["x-amz-content-sha256"], S3SigV4.emptyPayloadHash)
    }

    func testTheEmptyPayloadHashIsTheOneEveryVectorCarries() {
        XCTAssertEqual(
            S3SigV4.emptyPayloadHash,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: - 1. The GET Object vector

    func testTheSignerReproducesTheGetObjectVector() {
        let signed = S3SigV4.signInHeader(
            method: "GET",
            canonicalPath: "/test.txt",
            query: [],
            headers: [
                "host": "examplebucket.s3.amazonaws.com",
                "range": "bytes=0-9",
            ],
            payloadHash: S3SigV4.emptyPayloadHash,
            credentials: s3Credentials,
            region: "us-east-1",
            date: exampleDate)

        XCTAssertEqual(
            ContentHash.hex(ofUTF8: signed.canonicalRequest),
            "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972")
        XCTAssertEqual(
            signed.signature,
            "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        XCTAssertEqual(
            signed.headers["Authorization"],
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
                + " SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
                + " Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    // MARK: - 1. The PUT Object vector, whose key needs encoding

    func testTheSignerReproducesThePutObjectVector() {
        let body = Data("Welcome to Amazon S3.".utf8)
        let payloadHash = ContentHash.hex(of: body)
        XCTAssertEqual(
            payloadHash,
            "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")

        // The key is `test$file.text`. S3 encodes a path once, so the
        // canonical path carries `%24` and not `%2524`.
        XCTAssertEqual(S3SigV4.encodePath("test$file.text"), "test%24file.text")

        let signed = S3SigV4.signInHeader(
            method: "PUT",
            canonicalPath: "/" + S3SigV4.encodePath("test$file.text"),
            query: [],
            headers: [
                "host": "examplebucket.s3.amazonaws.com",
                "date": "Fri, 24 May 2013 00:00:00 GMT",
                "x-amz-storage-class": "REDUCED_REDUNDANCY",
            ],
            payloadHash: payloadHash,
            credentials: s3Credentials,
            region: "us-east-1",
            date: exampleDate)

        XCTAssertEqual(
            signed.signature,
            "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    // MARK: - 2. The presigned URL

    func testAPresignedURLReproducesTheQueryStringVector() {
        let presigned = S3SigV4.presign(
            method: "GET",
            scheme: "https",
            host: "examplebucket.s3.amazonaws.com",
            port: nil,
            canonicalPath: "/test.txt",
            credentials: s3Credentials,
            region: "us-east-1",
            date: exampleDate,
            expires: 86400)

        XCTAssertEqual(
            presigned?.signature,
            "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")

        let text = presigned?.url.absoluteString ?? ""
        XCTAssertTrue(text.hasPrefix("https://examplebucket.s3.amazonaws.com/test.txt?"))
        XCTAssertTrue(text.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
        XCTAssertTrue(
            text.contains(
                "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"))
        XCTAssertTrue(text.contains("X-Amz-Date=20130524T000000Z"))
        XCTAssertTrue(text.contains("X-Amz-Expires=86400"))
        XCTAssertTrue(text.contains("X-Amz-SignedHeaders=host"))
        XCTAssertTrue(
            text.hasSuffix(
                "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
        )
    }

    /// The same four steps, for the `PUT` that a blob upload signs.
    ///
    /// The expected value comes from the algorithm AWS publishes, run
    /// beside the four vectors above. A signer that reproduces those
    /// four and this one signs a `PutObject` right.
    func testAPresignedPutObjectURLSignsTheWholeWeek() {
        let presigned = S3SigV4.presign(
            method: "PUT",
            scheme: "https",
            host: "examplebucket.s3.amazonaws.com",
            port: nil,
            canonicalPath: "/Empo/devices/ns/blobs/ab/abcdef",
            credentials: s3Credentials,
            region: "us-east-1",
            date: exampleDate,
            expires: S3SigV4.maximumExpiry)

        XCTAssertEqual(
            presigned?.signature,
            "1f0f72deed1123ab947bf785d4f27fd9197d27ab0b33effb477ffcc1d8a87b58")
        XCTAssertTrue(presigned?.url.absoluteString.contains("X-Amz-Expires=604800") == true)
    }

    func testAPresignedKeyEncodesOnceInTheURLAndInTheSignature() {
        let presigned = S3SigV4.presign(
            method: "PUT",
            scheme: "https",
            host: "examplebucket.s3.amazonaws.com",
            port: nil,
            canonicalPath: "/" + S3SigV4.encodePath("test$file.text"),
            credentials: s3Credentials,
            region: "us-east-1",
            date: exampleDate,
            expires: S3SigV4.maximumExpiry)

        XCTAssertEqual(
            presigned?.signature,
            "6bcfdb4a5869ff90e0e7697fca870804732a5c47348e24cf292585bcf40e983d")
        XCTAssertTrue(presigned?.url.absoluteString.contains("/test%24file.text?") == true)
    }

    // MARK: - 2. A presigned URL expires

    func testAPresignedURLLivesForTheTimeItStates() {
        let presigned = S3SigV4.presign(
            method: "PUT", scheme: "https", host: "examplebucket.s3.amazonaws.com", port: nil,
            canonicalPath: "/test.txt", credentials: s3Credentials, region: "us-east-1",
            date: exampleDate, expires: 3600)

        XCTAssertEqual(presigned?.expiresAt, exampleDate.addingTimeInterval(3600))
        XCTAssertEqual(presigned?.isUsable(at: exampleDate.addingTimeInterval(3599)), true)
        XCTAssertEqual(presigned?.isUsable(at: exampleDate.addingTimeInterval(3601)), false)
    }

    func testAPresignedURLNeverStatesMoreThanTheSevenDaysOfNineFour() {
        let presigned = S3SigV4.presign(
            method: "PUT", scheme: "https", host: "examplebucket.s3.amazonaws.com", port: nil,
            canonicalPath: "/test.txt", credentials: s3Credentials, region: "us-east-1",
            date: exampleDate, expires: 30 * 24 * 60 * 60)

        XCTAssertEqual(S3SigV4.maximumExpiry, 604_800)
        XCTAssertTrue(presigned?.url.absoluteString.contains("X-Amz-Expires=604800") == true)
        XCTAssertEqual(
            presigned?.expiresAt, exampleDate.addingTimeInterval(S3SigV4.maximumExpiry))
    }

    // MARK: - The canonical form

    func testTheEncoderLeavesTheUnreservedSetAndEncodesTheRest() {
        XCTAssertEqual(S3SigV4.uriEncode("aZ0-_.~"), "aZ0-_.~")
        XCTAssertEqual(S3SigV4.uriEncode("a b"), "a%20b")
        XCTAssertEqual(S3SigV4.uriEncode("a/b"), "a%2Fb")
        XCTAssertEqual(S3SigV4.uriEncode("a/b", encodeSlash: false), "a/b")
        XCTAssertEqual(S3SigV4.uriEncode("+"), "%2B")
        // Every byte of a character outside ASCII encodes on its own.
        XCTAssertEqual(S3SigV4.uriEncode("é"), "%C3%A9")
    }

    func testTheCanonicalQuerySortsByNameThenByValue() {
        let query = S3SigV4.canonicalQuery([
            URLQueryItem(name: "uploadId", value: "abc/def"),
            URLQueryItem(name: "partNumber", value: "2"),
            URLQueryItem(name: "uploads", value: ""),
        ])
        XCTAssertEqual(query, "partNumber=2&uploadId=abc%2Fdef&uploads=")
    }

    func testTheCanonicalHeadersFoldTheCaseAndTheSpaces() {
        let canonical = S3SigV4.canonicalHeaders([
            "Host": "example.com",
            "X-Amz-Date": "  20130524T000000Z  ",
            "Content-Type": "text/plain;  charset=utf-8",
        ])
        XCTAssertEqual(canonical.signedNames, "content-type;host;x-amz-date")
        XCTAssertEqual(
            canonical.text,
            "content-type:text/plain; charset=utf-8\nhost:example.com\nx-amz-date:20130524T000000Z\n"
        )
    }

    // MARK: - The two helpers the suite vector needs

    private static func hmac(key: Data, text: String) -> Data {
        S3SigV4.hmac(key: key, text: text)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

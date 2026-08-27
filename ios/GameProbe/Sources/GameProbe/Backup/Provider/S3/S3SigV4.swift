import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// AWS Signature Version 4, by hand, per SPEC 9.4.
///
/// No AWS SDK ships. 9.4 states why: every SDK in this space brings
/// its own HTTP stack and cannot use a background URLSession
/// directly. The same reason keeps Dropbox and Google Drive
/// hand-rolled.
///
/// Empo signs two ways.
///
/// - **In a header.** The small calls that move no file take an
///   `Authorization` header. The service allows a 15-minute
///   difference between its clock and the stated time, which every
///   such call meets, because it goes out at once.
/// - **In the query, which is a presigned URL.** Every call that
///   moves a file takes one. A background URLSession hands the
///   transfer to a daemon that starts it when the system allows, and
///   that can be hours later. A header signature would already be
///   too old. A presigned URL lives up to 7 days, per 9.4.
///
/// The published AWS test vectors drive the checks in
/// `S3SigV4Tests`. Read the rules there before you change a line of
/// the canonical form: one wrong space or one wrong encoding turns
/// every request into 403 `SignatureDoesNotMatch`.
public enum S3SigV4 {

    /// The access key and the secret the user typed, per 9.4. They
    /// live in the Keychain, per 6.7, and never in a descriptor.
    public struct Credentials: Codable, Equatable, Sendable {
        public var accessKeyId: String
        public var secretAccessKey: String

        public init(accessKeyId: String, secretAccessKey: String) {
            self.accessKeyId = accessKeyId
            self.secretAccessKey = secretAccessKey
        }
    }

    public static let algorithm = "AWS4-HMAC-SHA256"
    /// The last step of the signing key.
    public static let terminator = "aws4_request"
    /// The service name in the credential scope. Every S3-compatible
    /// service takes this one, R2 and MinIO included.
    public static let service = "s3"

    /// What a presigned URL puts where the payload hash goes. The
    /// bytes are not there yet when Empo signs, so no hash of them
    /// can be.
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// The hash of no bytes at all, which every `GET` and `DELETE`
    /// carries in `x-amz-content-sha256`.
    public static let emptyPayloadHash = ContentHash.hex(of: Data())

    /// The longest life a presigned URL may state, per 9.4.
    public static let maximumExpiry: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - The two time forms

    /// `yyyyMMdd'T'HHmmss'Z'`, which every signature carries.
    public static func amzDate(_ date: Date) -> String {
        formatter(format: "yyyyMMdd'T'HHmmss'Z'").string(from: date)
    }

    /// `yyyyMMdd`, which the credential scope and the signing key
    /// carry.
    public static func dateStamp(_ date: Date) -> String {
        formatter(format: "yyyyMMdd").string(from: date)
    }

    /// `<date>/<region>/s3/aws4_request`.
    public static func scope(dateStamp: String, region: String) -> String {
        "\(dateStamp)/\(region)/\(service)/\(terminator)"
    }

    private static func formatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        // A fixed locale and a fixed zone. A user calendar of another
        // kind would write another year and every request would fail.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - The canonical form

    /// The characters AWS leaves as they are: the unreserved set of
    /// RFC 3986.
    private static let unreserved = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    /// One string, encoded the way SigV4 asks.
    ///
    /// Every byte outside the unreserved set becomes `%` plus two
    /// uppercase hex digits. A path keeps its separators, so it
    /// passes `encodeSlash: false`. S3 encodes a path once and never
    /// twice, which is why the path and the query use one encoder
    /// with one flag.
    public static func uriEncode(_ text: String, encodeSlash: Bool = true) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for byte in Array(text.utf8) {
            let character = Character(UnicodeScalar(byte))
            if unreserved.contains(character) {
                out.append(character)
            } else if byte == UInt8(ascii: "/"), !encodeSlash {
                out.append("/")
            } else {
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    /// A whole key as a path: encoded once, with the separators kept.
    public static func encodePath(_ path: String) -> String {
        uriEncode(path, encodeSlash: false)
    }

    /// The canonical query string: every item encoded, then sorted by
    /// name and by value.
    public static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        var encoded: [(name: String, value: String)] = []
        encoded.reserveCapacity(items.count)
        for item in items {
            encoded.append((uriEncode(item.name), uriEncode(item.value ?? "")))
        }
        encoded.sort { left, right in
            left.name == right.name ? left.value < right.value : left.name < right.name
        }
        var pairs: [String] = []
        pairs.reserveCapacity(encoded.count)
        for pair in encoded {
            pairs.append(pair.name + "=" + pair.value)
        }
        return pairs.joined(separator: "&")
    }

    /// The canonical headers and the names they cover.
    ///
    /// A name folds to lowercase and a value loses the space at each
    /// end and every run of spaces inside it. Two headers of one name
    /// would join with a comma, and Empo sends none, so this takes
    /// one value per name.
    public static func canonicalHeaders(
        _ headers: [String: String]
    ) -> (text: String, signedNames: String) {
        var folded: [(name: String, value: String)] = []
        folded.reserveCapacity(headers.count)
        for (name, value) in headers {
            let pieces: [Substring] = value.split(separator: " ")
            let tidy: String = pieces.joined(separator: " ")
            folded.append((name.lowercased(), tidy))
        }
        folded.sort { left, right in left.name < right.name }

        var text = ""
        var names: [String] = []
        for pair in folded {
            text += pair.name + ":" + pair.value + "\n"
            names.append(pair.name)
        }
        return (text, names.joined(separator: ";"))
    }

    /// The canonical request of step 1.
    public static func canonicalRequest(
        method: String,
        canonicalPath: String,
        canonicalQuery: String,
        headers: [String: String],
        payloadHash: String
    ) -> (text: String, signedNames: String) {
        let canonical = canonicalHeaders(headers)
        let text = [
            method.uppercased(),
            canonicalPath.isEmpty ? "/" : canonicalPath,
            canonicalQuery,
            canonical.text,
            canonical.signedNames,
            payloadHash,
        ].joined(separator: "\n")
        return (text, canonical.signedNames)
    }

    /// The string to sign of step 2.
    public static func stringToSign(
        amzDate: String, scope: String, canonicalRequest: String
    ) -> String {
        [
            algorithm, amzDate, scope,
            ContentHash.hex(of: Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
    }

    // MARK: - The key and the signature

    /// The signing key of step 3. It is the secret, walked through
    /// the date, the region, the service, and the terminator, so a
    /// key that leaks covers one day of one region alone.
    public static func signingKey(
        secretAccessKey: String, dateStamp: String, region: String
    ) -> Data {
        var key = Data("AWS4\(secretAccessKey)".utf8)
        for step in [dateStamp, region, service, terminator] {
            key = hmac(key: key, text: step)
        }
        return key
    }

    /// The signature of step 4, in lowercase hex.
    public static func signature(
        stringToSign: String, secretAccessKey: String, dateStamp: String, region: String
    ) -> String {
        let key = signingKey(
            secretAccessKey: secretAccessKey, dateStamp: dateStamp, region: region)
        return hex(hmac(key: key, text: stringToSign))
    }

    /// One HMAC-SHA256 step of the signing key.
    ///
    /// It is not private because the test that reproduces the SigV4
    /// test-suite vector signs the service name `service` and not
    /// `s3`, so it walks the four steps itself.
    static func hmac(key: Data, text: String) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(text.utf8), using: SymmetricKey(data: key))
        return Data(code)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The header signature

    /// What one signed request carries: the headers to add and the
    /// signature itself.
    public struct SignedRequest: Equatable, Sendable {
        /// Every header the request must send, the `Authorization`
        /// one included.
        public let headers: [String: String]
        public let signature: String
        public let canonicalRequest: String
        public let stringToSign: String

        public init(
            headers: [String: String], signature: String, canonicalRequest: String,
            stringToSign: String
        ) {
            self.headers = headers
            self.signature = signature
            self.canonicalRequest = canonicalRequest
            self.stringToSign = stringToSign
        }
    }

    /// Signs one request in its `Authorization` header.
    ///
    /// `headers` holds what the request already carries. This adds
    /// `x-amz-date`, `x-amz-content-sha256`, and `Authorization`.
    /// The host belongs in `headers`, because S3 signs it always.
    public static func signInHeader(
        method: String,
        canonicalPath: String,
        query: [URLQueryItem],
        headers: [String: String],
        payloadHash: String,
        credentials: Credentials,
        region: String,
        date: Date
    ) -> SignedRequest {
        let stamp = dateStamp(date)
        let amz = amzDate(date)
        var all = headers
        all["x-amz-date"] = amz
        all["x-amz-content-sha256"] = payloadHash

        let canonical = canonicalRequest(
            method: method,
            canonicalPath: canonicalPath,
            canonicalQuery: canonicalQuery(query),
            headers: all,
            payloadHash: payloadHash)
        let credentialScope = scope(dateStamp: stamp, region: region)
        let toSign = stringToSign(
            amzDate: amz, scope: credentialScope, canonicalRequest: canonical.text)
        let signed = signature(
            stringToSign: toSign, secretAccessKey: credentials.secretAccessKey,
            dateStamp: stamp, region: region)

        all["Authorization"] =
            "\(algorithm) Credential=\(credentials.accessKeyId)/\(credentialScope),"
            + " SignedHeaders=\(canonical.signedNames), Signature=\(signed)"
        return SignedRequest(
            headers: all, signature: signed, canonicalRequest: canonical.text,
            stringToSign: toSign)
    }

    // MARK: - The presigned URL

    /// One presigned URL and the moment it stops working.
    public struct PresignedURL: Equatable, Sendable {
        public let url: URL
        public let signature: String
        public let expiresAt: Date

        public init(url: URL, signature: String, expiresAt: Date) {
            self.url = url
            self.signature = signature
            self.expiresAt = expiresAt
        }

        public func isUsable(at moment: Date) -> Bool { moment < expiresAt }
    }

    /// Signs one call in the query string, per 9.4.
    ///
    /// `host` is the only signed header, which is what lets the
    /// background daemon send the request without a header of its
    /// own. `expires` is clamped to the 7 days of 9.4.
    public static func presign(
        method: String,
        scheme: String,
        host: String,
        port: Int?,
        canonicalPath: String,
        query: [URLQueryItem] = [],
        credentials: Credentials,
        region: String,
        date: Date,
        expires: TimeInterval = maximumExpiry
    ) -> PresignedURL? {
        let stamp = dateStamp(date)
        let amz = amzDate(date)
        let life = min(max(1, expires.rounded()), maximumExpiry)
        let credentialScope = scope(dateStamp: stamp, region: region)

        var items = query
        items.append(URLQueryItem(name: "X-Amz-Algorithm", value: algorithm))
        items.append(
            URLQueryItem(
                name: "X-Amz-Credential", value: "\(credentials.accessKeyId)/\(credentialScope)"))
        items.append(URLQueryItem(name: "X-Amz-Date", value: amz))
        items.append(URLQueryItem(name: "X-Amz-Expires", value: String(Int(life))))
        items.append(URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"))

        let canonicalItems = canonicalQuery(items)
        let canonical = canonicalRequest(
            method: method,
            canonicalPath: canonicalPath,
            canonicalQuery: canonicalItems,
            headers: ["host": host],
            payloadHash: unsignedPayload)
        let toSign = stringToSign(
            amzDate: amz, scope: credentialScope, canonicalRequest: canonical.text)
        let signed = signature(
            stringToSign: toSign, secretAccessKey: credentials.secretAccessKey,
            dateStamp: stamp, region: region)

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.percentEncodedPath = canonicalPath.isEmpty ? "/" : canonicalPath
        // The canonical query is already sorted and encoded, so the
        // URL and the signature read the same string.
        components.percentEncodedQuery = "\(canonicalItems)&X-Amz-Signature=\(signed)"
        guard let url = components.url else { return nil }
        return PresignedURL(
            url: url, signature: signed, expiresAt: date.addingTimeInterval(life))
    }
}

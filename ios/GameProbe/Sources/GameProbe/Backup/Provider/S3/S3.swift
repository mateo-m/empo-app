import Foundation

/// The S3-compatible rules of SPEC 9.4 that need no network.
///
/// This is the bring-your-own-bucket option, and it covers AWS S3,
/// Cloudflare R2, MinIO, and the S3 API of Backblaze B2. It is the
/// first target the user hosts themselves, so it is the first one
/// that carries the storage warning of 5.7 on its add form.
///
/// The bucket needs an access key, so the provider itself lives in
/// the app target. Everything a test can reach lives here: the
/// queries, the upload plan, the paging of a list, the body of a
/// commit, and the map from an S3 failure onto the seven error kinds
/// of 8.4. `S3SigV4` holds the signature.
///
/// **There is no space query.** The API has no free-space call, so
/// `canQueryQuota` is false and the limit shows up as an upload
/// error, per 9.7. 13.6 states what the target screen shows in place
/// of the usage bar.
public enum S3 {

    public static let capabilities = TargetCapabilities(
        canQueryQuota: false,
        reportsObjectAge: true,
        supportsBackgroundTransfer: true,
        maxFileSize: S3.maxFileSizeBytes,
        foldsCase: false)

    // MARK: - The sizes of 9.4

    /// The largest single `PutObject`, per 9.4. It is also the
    /// largest part of a multipart upload.
    public static let singleUploadLimitBytes: Int64 = 5 * 1024 * 1024 * 1024

    /// Every part but the last is at least this large.
    public static let minimumPartBytes: Int64 = 5 * 1024 * 1024

    /// One multipart upload holds at most this many parts.
    public static let maximumPartCount = 10_000

    /// What one part holds before the file size forces a larger one.
    ///
    /// Each part goes to disk on its own before it goes up, because a
    /// background URLSession uploads from a file. 32 MB is what that
    /// costs at one moment, and it carries a file of up to 320 GB
    /// inside the part limit.
    public static let defaultPartBytes: Int64 = 32 * 1024 * 1024

    /// The largest file AWS takes: 10,000 parts of 5 GiB, which is
    /// 48.8 TiB, per 9.4.
    public static let awsMaxFileSizeBytes = Int64(maximumPartCount) * singleUploadLimitBytes

    /// The largest file R2 takes: 4.995 TiB, per 9.4.
    public static let r2MaxFileSizeBytes: Int64 = 1024 * 1024 * 1024 * 1024 * 4995 / 1000

    /// The number the capability flag of 8.3 carries.
    ///
    /// One provider covers four services and Empo cannot tell them
    /// apart from the address alone, so it takes the smaller of the
    /// two numbers 9.4 states. No snapshot of a fangame reaches
    /// either one, and the smaller number refuses nothing a save
    /// tree can hold.
    public static let maxFileSizeBytes = r2MaxFileSizeBytes

    // MARK: - The upload plan of 9.4

    /// One part of a multipart upload. S3 numbers parts from 1.
    public struct Part: Equatable, Sendable {
        public let number: Int
        public let offset: Int64
        public let length: Int64

        public init(number: Int, offset: Int64, length: Int64) {
            self.number = number
            self.offset = offset
            self.length = length
        }

        public var endOffset: Int64 { offset + length }
    }

    /// How one file goes up, per 9.4.
    public enum UploadPlan: Equatable, Sendable {
        /// One `PutObject`. S3 commits a key whole, so it meets 8.2
        /// on its own.
        case single
        /// `CreateMultipartUpload`, a `UploadPart` per part, and a
        /// `CompleteMultipartUpload` that is the commit of 8.2. The
        /// key holds nothing until the commit answers.
        case multipart(parts: [Part])
    }

    /// What one part holds for a file of this size.
    ///
    /// It grows only when 10,000 parts of the default size would not
    /// carry the file, and it stops at the 5 GiB part limit.
    public static func partSize(
        forFileOfSize size: Int64, base: Int64 = defaultPartBytes
    ) -> Int64 {
        let floor = max(minimumPartBytes, base)
        let needed = (size + Int64(maximumPartCount) - 1) / Int64(maximumPartCount)
        let rounded =
            ((max(floor, needed) + minimumPartBytes - 1) / minimumPartBytes)
            * minimumPartBytes
        return min(rounded, singleUploadLimitBytes)
    }

    /// The plan for one file, per 9.4.
    ///
    /// `singleLimit` and `base` are inputs so a device check can
    /// lower them and drive the multipart path with a small file,
    /// which ticket 011 asks for.
    public static func uploadPlan(
        forFileOfSize size: Int64,
        singleLimit: Int64 = singleUploadLimitBytes,
        base: Int64 = defaultPartBytes
    ) -> UploadPlan {
        guard size > singleLimit else { return .single }
        return .multipart(parts: parts(ofFileSize: size, partSize: partSize(forFileOfSize: size, base: base)))
    }

    /// Every part of a file of this size.
    public static func parts(ofFileSize size: Int64, partSize: Int64) -> [Part] {
        guard size > 0, partSize > 0 else { return [] }
        var parts: [Part] = []
        var offset: Int64 = 0
        var number = 1
        while offset < size {
            let length = min(partSize, size - offset)
            parts.append(Part(number: number, offset: offset, length: length))
            offset += length
            number += 1
        }
        return parts
    }

    // MARK: - The queries of each call

    /// The most keys one `ListObjectsV2` page holds. S3 caps it at
    /// 1000 and answers a continuation token for the rest.
    public static let pageSize = 1000

    public static func listQuery(prefix: String, continuationToken: String? = nil) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "max-keys", value: String(pageSize)),
        ]
        if !prefix.isEmpty { items.append(URLQueryItem(name: "prefix", value: prefix)) }
        if let continuationToken, !continuationToken.isEmpty {
            items.append(URLQueryItem(name: "continuation-token", value: continuationToken))
        }
        return items
    }

    /// `CreateMultipartUpload`, and `ListMultipartUploads` when it
    /// carries a prefix.
    public static func uploadsQuery(prefix: String? = nil) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "uploads", value: "")]
        if let prefix, !prefix.isEmpty {
            items.append(URLQueryItem(name: "prefix", value: prefix))
        }
        return items
    }

    public static func partQuery(number: Int, uploadId: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "partNumber", value: String(number)),
            URLQueryItem(name: "uploadId", value: uploadId),
        ]
    }

    /// `CompleteMultipartUpload`, `AbortMultipartUpload`, and
    /// `ListParts` all name the upload and nothing else.
    public static func uploadQuery(uploadId: String) -> [URLQueryItem] {
        [URLQueryItem(name: "uploadId", value: uploadId)]
    }

    // MARK: - The commit body

    /// One part as the service reported it.
    public struct CompletedPart: Codable, Equatable, Sendable {
        public let number: Int
        /// The tag the service answered. It carries its own quotes,
        /// and the commit body sends it back as it came.
        public let eTag: String

        public init(number: Int, eTag: String) {
            self.number = number
            self.eTag = eTag
        }
    }

    /// The body of `CompleteMultipartUpload`, which is the commit of
    /// 8.2.
    ///
    /// The parts go in order of their number. A service refuses a
    /// body that lists them any other way.
    public static func completeBody(parts: [CompletedPart]) -> Data {
        var text = "<CompleteMultipartUpload>"
        for part in parts.sorted(by: { $0.number < $1.number }) {
            text += "<Part><PartNumber>\(part.number)</PartNumber>"
            text += "<ETag>\(S3XML.escape(part.eTag))</ETag></Part>"
        }
        text += "</CompleteMultipartUpload>"
        return Data(text.utf8)
    }

    // MARK: - Reading an answer

    /// One object of a page.
    public struct Object: Equatable, Sendable {
        public let key: String
        public let sizeBytes: Int64
        public let lastModified: Date?

        public init(key: String, sizeBytes: Int64, lastModified: Date?) {
            self.key = key
            self.sizeBytes = sizeBytes
            self.lastModified = lastModified
        }
    }

    /// One page of `ListObjectsV2`, per 9.4.
    public struct ObjectPage: Equatable, Sendable {
        public let objects: [Object]
        /// The token of the next page, or `nil` on the last one.
        public let nextContinuationToken: String?

        public init(objects: [Object], nextContinuationToken: String?) {
            self.objects = objects
            self.nextContinuationToken = nextContinuationToken
        }

        public var hasMore: Bool {
            guard let nextContinuationToken else { return false }
            return !nextContinuationToken.isEmpty
        }
    }

    /// S3 stamps `LastModified` in RFC 3339, with a fraction of a
    /// second on some services and none on others.
    public static func date(fromTimestamp text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    public static func page(fromBody body: Data) -> ObjectPage? {
        guard let xml = String(data: body, encoding: .utf8) else { return nil }
        guard xml.contains("<ListBucketResult") else { return nil }
        let objects = S3XML.blocks(named: "Contents", in: xml).compactMap { block -> Object? in
            guard let key = S3XML.value(of: "Key", in: block), !key.isEmpty else { return nil }
            return Object(
                key: key,
                sizeBytes: S3XML.int64("Size", in: block) ?? 0,
                lastModified: S3XML.value(of: "LastModified", in: block)
                    .flatMap(date(fromTimestamp:)))
        }
        // A page that is not truncated carries no token, and a
        // service that sends one anyway means nothing by it.
        let token =
            S3XML.flag("IsTruncated", in: xml)
            ? S3XML.value(of: "NextContinuationToken", in: xml) : nil
        return ObjectPage(objects: objects, nextContinuationToken: token)
    }

    /// Every object of every page, as `list` reports them, per 8.1.
    ///
    /// The result is sorted, because 8.1 states a flat namespace and
    /// two callers compare two lists.
    public static func objects(fromPages pages: [ObjectPage]) -> [RemoteObject] {
        pages
            .flatMap(\.objects)
            .map {
                RemoteObject(
                    path: $0.key, sizeBytes: $0.sizeBytes, modifiedAt: $0.lastModified)
            }
            .sorted { $0.path < $1.path }
    }

    /// The id `CreateMultipartUpload` answered.
    public static func uploadId(fromBody body: Data) -> String? {
        guard let xml = String(data: body, encoding: .utf8) else { return nil }
        guard let id = S3XML.value(of: "UploadId", in: xml), !id.isEmpty else { return nil }
        return id
    }

    /// The parts `ListParts` reports, which is what a resumed upload
    /// reads before it sends a byte.
    public static func completedParts(fromBody body: Data) -> [CompletedPart] {
        guard let xml = String(data: body, encoding: .utf8) else { return [] }
        return S3XML.blocks(named: "Part", in: xml).compactMap { block in
            guard let number = S3XML.int64("PartNumber", in: block),
                let eTag = S3XML.value(of: "ETag", in: block), !eTag.isEmpty
            else { return nil }
            return CompletedPart(number: Int(number), eTag: eTag)
        }
        .sorted { $0.number < $1.number }
    }

    /// The upload ids `ListMultipartUploads` reports for one key.
    ///
    /// An abandoned multipart upload leaves parts, and parts cost
    /// money, per 9.4. A new upload of the same key aborts every one
    /// of these first.
    public static func uploadIds(fromBody body: Data, key: String) -> [String] {
        guard let xml = String(data: body, encoding: .utf8) else { return [] }
        return S3XML.blocks(named: "Upload", in: xml).compactMap { block in
            guard S3XML.value(of: "Key", in: block) == key else { return nil }
            guard let id = S3XML.value(of: "UploadId", in: block), !id.isEmpty else { return nil }
            return id
        }
    }

    // MARK: - Throttling, per 9.4

    /// The wait when the service throttles and states no time.
    public static let defaultRetryAfter: TimeInterval = 2

    /// The longest wait the truncated backoff ever makes.
    public static let backoffCeilingSeconds: TimeInterval = 64

    /// The truncated exponential delay for attempt 1, 2, 3, and so
    /// on. It doubles and then stops at the ceiling.
    public static func backoffSeconds(attempt: Int) -> TimeInterval {
        let step = max(1, attempt)
        guard step < 32 else { return backoffCeilingSeconds }
        return min(backoffCeilingSeconds, TimeInterval(1 << (step - 1)))
    }

    /// `Retry-After` in seconds, per 8.6. S3 states it in seconds
    /// when it states it at all, and the backoff covers the rest.
    public static func retryAfterSeconds(_ header: String?, attempt: Int = 1) -> TimeInterval {
        guard let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
            seconds > 0
        else {
            return backoffSeconds(attempt: attempt)
        }
        return seconds
    }

    // MARK: - The error map, per 8.4

    /// What an S3 failure body carries.
    public struct Failure: Equatable, Sendable {
        /// The code, such as `SignatureDoesNotMatch`.
        public let code: String
        /// The sentence the service wrote.
        public let message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    /// Reads the failure body. Every S3-compatible service answers
    /// `<Error><Code>…</Code><Message>…</Message></Error>`.
    public static func failure(inBody body: Data) -> Failure {
        guard let xml = String(data: body, encoding: .utf8) else {
            return Failure(code: "", message: "")
        }
        return Failure(
            code: S3XML.value(of: "Code", in: xml) ?? "",
            message: S3XML.value(of: "Message", in: xml) ?? "")
    }

    /// The status codes, named so the map below reads as the rule.
    public enum Status {
        public static let ok = 200
        public static let noContent = 204
        public static let badRequest = 400
        public static let unauthorized = 401
        public static let forbidden = 403
        public static let notFound = 404
        public static let conflict = 409
        public static let tooManyRequests = 429
        public static let serverError = 500
        /// The service scales, per 9.4. It also carries `SlowDown`.
        public static let unavailable = 503
        public static let insufficientStorage = 507
    }

    /// The codes that mean the bucket, the account, or the cap has no
    /// room left. The API has no free-space call, so this is the one
    /// place Empo learns it, per 9.7.
    private static let outOfSpaceCodes: Set<String> = [
        "QuotaExceeded", "StorageQuotaExceeded", "StorageCapExceeded",
        "InsufficientStorage", "XMinioStorageFull",
    ]

    /// The codes that mean "slow down".
    private static let throttleCodes: Set<String> = [
        "SlowDown", "RequestThrottled", "RequestThrottledException", "TooManyRequests",
        "ServiceUnavailable", "RequestLimitExceeded",
    ]

    /// The codes that mean the key or the upload is not there.
    private static let notFoundCodes: Set<String> = [
        "NoSuchKey", "NoSuchUpload", "NotFound",
    ]

    /// One S3 failure onto one error kind of 8.4.
    public static func error(
        status: Int,
        failure: Failure = Failure(code: "", message: ""),
        retryAfterHeader: String? = nil,
        attempt: Int = 1
    ) -> BackupProviderError {
        if outOfSpaceCodes.contains(failure.code) { return .outOfSpace }
        if throttleCodes.contains(failure.code) {
            return .throttled(retryAfter: retryAfterSeconds(retryAfterHeader, attempt: attempt))
        }

        switch status {
        case Status.unauthorized:
            return .authExpired
        case Status.forbidden:
            return forbidden(failure)
        case Status.notFound:
            // A bucket that is not there is permanent, and no later
            // pass makes one. Only a missing key drops from the
            // cache and uploads again, per 8.4.
            if failure.code == "NoSuchBucket" {
                return .rejected(message: message(from: failure, status: status))
            }
            return .notFound
        case Status.conflict:
            if notFoundCodes.contains(failure.code) { return .notFound }
            return .rejected(message: message(from: failure, status: status))
        case Status.tooManyRequests, Status.unavailable:
            return .throttled(retryAfter: retryAfterSeconds(retryAfterHeader, attempt: attempt))
        case Status.insufficientStorage:
            return .outOfSpace
        case Status.serverError..<600:
            // The service is up but unwell. 8.4 retries on the next
            // pass.
            return .offline
        default:
            return .rejected(message: message(from: failure, status: status))
        }
    }

    private static func forbidden(_ failure: Failure) -> BackupProviderError {
        switch failure.code {
        case "SignatureDoesNotMatch", "AccessDenied", "AllAccessDisabled",
            "InvalidBucketState":
            // The key works and the rights do not cover the call. A
            // re-sign-in does not add a right, so 8.4 blocks the
            // target, per 9.4.
            return .permissionDenied
        case "InvalidAccessKeyId", "ExpiredToken", "TokenRefreshRequired":
            // The service does not know this key any more. The fix is
            // a new key, which is what needs-sign-in asks for.
            return .authExpired
        default:
            return .rejected(message: message(from: failure, status: Status.forbidden))
        }
    }

    /// What a `rejected` shows the user, word for word, per 8.4.
    private static func message(from failure: Failure, status: Int) -> String {
        let text = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = failure.code.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && code.isEmpty { return "the bucket answered \(status)" }
        if text.isEmpty { return "the bucket answered \(status): \(code)" }
        return "the bucket answered \(status): \(text)"
    }

    /// Whether a failed upload has to abort what it started.
    ///
    /// An abandoned multipart upload leaves parts on the service and
    /// parts cost money, per 9.4. A failure that stops the run is
    /// permanent, so nothing later would ever finish that upload and
    /// the parts would sit there. A throttle or an offline device is
    /// not permanent, and the next pass carries on from the same id,
    /// so those keep their parts.
    ///
    /// `outOfSpace` keeps them too: the prune ladder of 5.14 runs and
    /// the retry that follows uses the parts already there.
    public static func abortsMultipart(after error: BackupProviderError) -> Bool {
        error.effect.stopsTheRun
    }

    /// Whether the service dropped the multipart upload, so the
    /// bytes have to start again under a new id.
    public static func isUploadGone(status: Int, failure: Failure) -> Bool {
        failure.code == "NoSuchUpload"
            || (status == Status.notFound && failure.code.isEmpty)
    }

    // MARK: - The add form of 13.7

    /// The fields the add form shows, and the one line beside the
    /// address, per 13.7. Ticket 016 builds the form.
    ///
    /// The address carries the warning of 5.7, because that is the
    /// moment the user types someone else's host name.
    public static let addFormFields: [TargetFormField] = [
        TargetFormField(
            name: "label", label: "Name", hint: "My bucket"),
        TargetFormField(
            name: "address", label: "Address",
            hint: "https://s3.eu-west-1.amazonaws.com",
            note: TransportSecurity.storageWarning),
        TargetFormField(name: "bucket", label: "Bucket", hint: "my-saves"),
        TargetFormField(name: "region", label: "Region", hint: "eu-west-1"),
        TargetFormField(
            name: "root", label: "Folder in the bucket", hint: "empo", isRequired: false),
        TargetFormField(name: "accessKeyId", label: "Access key", hint: ""),
        TargetFormField(
            name: "secretAccessKey", label: "Secret key", hint: "", kind: .secret),
        TargetFormField(
            name: "usesPathStyle", label: "Put the bucket name in the path", kind: .toggle,
            isRequired: false),
    ]

    /// What the target screen shows in place of a usage bar, per
    /// 13.6. This target answers no space query.
    public static let noSpaceQueryLine = "This service does not report free space."
}

import Foundation

/// The Google Drive rules of SPEC 9.3 that need no network.
///
/// The account needs a real sign-in, so the provider itself lives in
/// the app target. Everything a test can reach lives here: the URLs,
/// the queries, the framing of a resumable upload, the paging of a
/// list, the space query, and the map from a Drive failure onto the
/// seven error kinds of 8.4.
///
/// Empo hand-rolls this REST over the one background session of 7.3,
/// with AppAuth for PKCE, per 9.3. This is the same shape ticket 009
/// built for Dropbox, and it reuses that OAuth code.
///
/// **Drive has no path model.** A Drive file is an id plus a name plus
/// a list of parents. 8.1 states a flat namespace with no directory
/// model, so every object Empo writes is a direct child of the
/// `Empo Backups` folder and its Drive name is the whole Empo path.
/// One `files.list` under that folder then answers `list` for any
/// prefix, and the prefix filter runs here, the way it does for
/// Dropbox.
public enum GoogleDrive {

    /// The folder Empo creates, per 9.3. Under `drive.file` Empo sees
    /// only the files it created, so this folder and its children are
    /// the whole account as far as Empo is concerned.
    public static let rootFolderName = "Empo Backups"

    /// What Drive calls a folder.
    public static let folderMimeType = "application/vnd.google-apps.folder"

    /// The root the descriptor carries, per 8.7. It is empty because
    /// the `Empo Backups` folder is already the root the grant can
    /// reach, and the layout of 5.1 starts at `Empo/` inside it.
    public static let root = ""

    /// The one scope, per 9.3. `drive.file` is non-sensitive, so no
    /// scope verification and no CASA assessment apply, and the
    /// unverified-app screen with its 100-new-user cap never fires.
    public static let scope = "https://www.googleapis.com/auth/drive.file"

    public static let capabilities = TargetCapabilities(
        canQueryQuota: true,
        reportsObjectAge: true,
        supportsBackgroundTransfer: true,
        maxFileSize: GoogleDrive.maxFileSizeBytes,
        foldsCase: false)

    /// 5 TB, per 9.3.
    public static let maxFileSizeBytes: Int64 = 5 * 1000 * 1000 * 1000 * 1000

    // MARK: - The endpoints

    public static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    /// Metadata calls: list, create, update, and delete.
    public static let filesEndpoint = "https://www.googleapis.com/drive/v3/files"
    /// The upload host. Drive keeps the bytes on a second path.
    public static let uploadEndpoint = "https://www.googleapis.com/upload/drive/v3/files"
    /// The space query of 9.3.
    public static let aboutEndpoint = "https://www.googleapis.com/drive/v3/about"

    /// The fields one page carries. Drive sends nothing but the id
    /// unless the request names the fields it wants.
    public static let listFields = "nextPageToken,files(id,name,size,modifiedTime,mimeType)"

    /// The most files one page holds. Drive caps it at 1000.
    public static let pageSize = 1000

    /// The URL of one `files.list` page.
    public static func filesListURL(query: String, pageToken: String? = nil) -> URL? {
        var components = URLComponents(string: filesEndpoint)
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: listFields),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "spaces", value: "drive"),
        ]
        if let pageToken, !pageToken.isEmpty {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components?.queryItems = items
        return components?.url
    }

    /// The URL that creates one folder or reads one file's metadata.
    public static func filesURL(id: String? = nil, alt: String? = nil) -> URL? {
        let base = id.map { "\(filesEndpoint)/\($0)" } ?? filesEndpoint
        var components = URLComponents(string: base)
        if let alt {
            components?.queryItems = [URLQueryItem(name: "alt", value: alt)]
        }
        return components?.url
    }

    /// The upload URL. An id turns the call into an update, which
    /// replaces the content of the file that already holds the path.
    ///
    /// An update is what keeps a second run of the same blob on one
    /// object. Without it Drive would take the same name twice and
    /// the path would hold two files.
    public static func uploadURL(uploadType: String, fileId: String? = nil) -> URL? {
        let base = fileId.map { "\(uploadEndpoint)/\($0)" } ?? uploadEndpoint
        var components = URLComponents(string: base)
        components?.queryItems = [
            URLQueryItem(name: "uploadType", value: uploadType),
            URLQueryItem(name: "fields", value: "id,name,size,modifiedTime"),
        ]
        return components?.url
    }

    public static func aboutURL() -> URL? {
        var components = URLComponents(string: aboutEndpoint)
        components?.queryItems = [URLQueryItem(name: "fields", value: "storageQuota")]
        return components?.url
    }

    // MARK: - The queries

    /// One string inside a Drive query.
    ///
    /// Drive quotes a value with single quotes, so a value that holds
    /// one has to escape it. Every name Empo writes is a hex key or a
    /// fixed ASCII name, per 5.2, so this changes nothing today and
    /// keeps a later name from breaking a query.
    public static func quoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    /// Every object under the root folder.
    public static func childrenQuery(parentId: String) -> String {
        "\(quoted(parentId)) in parents and trashed = false"
    }

    /// The one object that holds this path, by name.
    public static func nameQuery(name: String, parentId: String) -> String {
        "name = \(quoted(name)) and \(quoted(parentId)) in parents and trashed = false"
    }

    /// The `Empo Backups` folder, if the grant already made one.
    ///
    /// It names no parent. `drive.file` already limits the answer to
    /// the files this OAuth client created, and the user may have
    /// moved the folder somewhere else in their Drive.
    public static func rootFolderQuery() -> String {
        "name = \(quoted(rootFolderName)) and mimeType = \(quoted(folderMimeType))"
            + " and trashed = false"
    }

    // MARK: - The OAuth callback

    /// The custom scheme an iOS OAuth client answers on, per 8.10.
    ///
    /// Google gives an iOS client the reversed form of its own id.
    /// A client id reads `<number>-<hash>.apps.googleusercontent.com`
    /// and its scheme reads `com.googleusercontent.apps.<number>-<hash>`.
    /// An id in another form has no scheme, and the sign-in then
    /// refuses rather than guessing.
    public static func redirectScheme(clientId: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(suffix) else { return nil }
        let head = String(id.dropLast(suffix.count))
        guard !head.isEmpty else { return nil }
        return "com.googleusercontent.apps.\(head)"
    }

    /// The callback URL AppAuth waits on. It is a custom scheme and
    /// never an https link, per 8.10.
    public static func redirectURL(clientId: String) -> URL? {
        guard let scheme = redirectScheme(clientId: clientId) else { return nil }
        return URL(string: "\(scheme):/oauth2redirect")
    }

    // MARK: - Upload framing

    /// A file up to this size goes up in one request, per 9.3.
    /// Anything larger takes a resumable session.
    public static let simpleUploadLimitBytes: Int64 = 5 * 1024 * 1024

    /// Every chunk but the last is a multiple of this, per 9.3.
    public static let chunkAlignmentBytes: Int64 = 256 * 1024

    /// One chunk of a resumable upload. It is a multiple of the
    /// alignment, and it trades disk against the work one failed
    /// chunk repeats.
    public static let uploadChunkBytes: Int64 = 64 * chunkAlignmentBytes

    /// A session URI expires after one week, per 9.3.
    public static let uploadSessionLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// One chunk of a resumable upload.
    public struct Chunk: Equatable, Sendable {
        public let offset: Int64
        public let length: Int64
        /// Whether the session ends after this one. Drive commits the
        /// file at the end of the last chunk, which is how a
        /// resumable upload meets 8.2.
        public let isLast: Bool

        public init(offset: Int64, length: Int64, isLast: Bool) {
            self.offset = offset
            self.length = length
            self.isLast = isLast
        }

        public var endOffset: Int64 { offset + length }
    }

    /// How one file goes up, per 9.3.
    public enum UploadPlan: Equatable, Sendable {
        /// One multipart request. Drive commits it whole, so it meets
        /// 8.2 on its own.
        case simple
        /// A session URI, then a `PUT` per chunk. The file appears
        /// only when the session ends, so the commit is atomic.
        case resumable(chunks: [Chunk])
    }

    public static func uploadPlan(forFileOfSize size: Int64) -> UploadPlan {
        guard size > simpleUploadLimitBytes else { return .simple }
        return .resumable(chunks: chunks(ofFileSize: size, from: 0))
    }

    /// The chunks left for a file of this size, starting at `offset`.
    ///
    /// A session that broke resumes from the offset the probe
    /// reports, so it never starts again from zero. Every chunk but
    /// the last is a multiple of 256 KB, which is what Drive takes.
    public static func chunks(ofFileSize size: Int64, from offset: Int64) -> [Chunk] {
        let start = max(0, min(offset, size))
        guard start < size else { return [] }

        var chunks: [Chunk] = []
        var cursor = start
        while cursor < size {
            let left = size - cursor
            let length = left <= uploadChunkBytes ? left : uploadChunkBytes
            cursor += length
            chunks.append(Chunk(offset: cursor - length, length: length, isLast: cursor >= size))
        }
        return chunks
    }

    /// The `Content-Range` header of one chunk.
    public static func contentRange(of chunk: Chunk, fileSize: Int64) -> String {
        "bytes \(chunk.offset)-\(chunk.endOffset - 1)/\(fileSize)"
    }

    /// The `Content-Range` header that asks Drive how far the session
    /// got. The request carries no bytes.
    public static func probeContentRange(fileSize: Int64) -> String {
        "bytes */\(fileSize)"
    }

    /// The offset to carry on from, out of the `Range` header of a
    /// 308 answer.
    ///
    /// Drive writes the bytes it holds, such as `bytes=0-262143`, so
    /// the next chunk starts one past the end. A 308 with no header
    /// means Drive holds nothing yet.
    public static func resumeOffset(fromRangeHeader header: String?) -> Int64 {
        guard let header else { return 0 }
        let text = header.trimmingCharacters(in: .whitespaces)
        guard let equals = text.firstIndex(of: "="),
            let dash = text.lastIndex(of: "-"), dash > equals
        else {
            return 0
        }
        let last = text[text.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        guard let end = Int64(last), end >= 0 else { return 0 }
        return end + 1
    }

    // MARK: - The multipart body of a simple upload

    /// The boundary of one multipart body. It is random so that no
    /// content can carry it by accident.
    public static func multipartBoundary() -> String {
        "empo-\(BackupKeys.randomHex(characters: 24))"
    }

    public static func multipartContentType(boundary: String) -> String {
        "multipart/related; boundary=\(boundary)"
    }

    /// The head of a `multipart/related` body, before the file bytes.
    ///
    /// A simple upload carries the metadata and the content in one
    /// request, so Drive learns the name and the parent from the same
    /// call that sends the bytes.
    public static func multipartHead(metadata: String, boundary: String) -> Data {
        var text = "--\(boundary)\r\n"
        text += "Content-Type: application/json; charset=UTF-8\r\n\r\n"
        text += metadata
        text += "\r\n--\(boundary)\r\n"
        text += "Content-Type: application/octet-stream\r\n\r\n"
        return Data(text.utf8)
    }

    public static func multipartTail(boundary: String) -> Data {
        Data("\r\n--\(boundary)--\r\n".utf8)
    }

    /// The metadata of one object, as a create sends it.
    ///
    /// The name is the whole Empo path, because Drive has no path
    /// model and 8.1 states a flat namespace.
    public static func metadata(name: String, parentId: String?) -> String {
        var value: [String: Any] = ["name": name]
        if let parentId { value["parents"] = [parentId] }
        return json(value)
    }

    /// The metadata of the `Empo Backups` folder.
    public static func folderMetadata() -> String {
        json(["name": rootFolderName, "mimeType": folderMimeType])
    }

    private static func json(_ value: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    // MARK: - Throttling, per 9.3

    /// The status codes Drive answers, named so the map below reads
    /// as the rule and not as a table of numbers.
    public enum Status {
        public static let ok = 200
        public static let created = 201
        /// The session lives and Drive wants the next chunk.
        public static let resumeIncomplete = 308
        public static let badRequest = 400
        public static let unauthorized = 401
        public static let forbidden = 403
        public static let notFound = 404
        public static let gone = 410
        public static let tooManyRequests = 429
        public static let serverError = 500
    }

    /// The wait when Drive throttles and states no time.
    public static let defaultRetryAfter: TimeInterval = 2

    /// The longest wait the truncated backoff of 9.3 ever makes.
    public static let backoffCeilingSeconds: TimeInterval = 64

    /// The truncated exponential delay of 9.3, for attempt 1, 2, 3,
    /// and so on. It doubles and then stops at the ceiling.
    public static func backoffSeconds(attempt: Int) -> TimeInterval {
        let step = max(1, attempt)
        guard step < 32 else { return backoffCeilingSeconds }
        return min(backoffCeilingSeconds, TimeInterval(1 << (step - 1)))
    }

    /// `Retry-After` in seconds, per 8.6. Drive states it in seconds
    /// when it states it at all, and the backoff of 9.3 covers the
    /// rest.
    public static func retryAfterSeconds(_ header: String?, attempt: Int = 1) -> TimeInterval {
        guard let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
            seconds > 0
        else {
            return backoffSeconds(attempt: attempt)
        }
        return seconds
    }

    // MARK: - The error map, per 8.4

    /// What a Drive failure body carries.
    public struct Failure: Equatable, Sendable {
        /// The reason of the first error, such as `storageQuotaExceeded`.
        public let reason: String
        /// The sentence Drive wrote.
        public let message: String

        public init(reason: String, message: String) {
            self.reason = reason
            self.message = message
        }
    }

    /// Reads the failure body Drive sends.
    public static func failure(inBody body: Data) -> Failure {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = root["error"] as? [String: Any]
        else {
            return Failure(reason: "", message: "")
        }
        let errors = error["errors"] as? [[String: Any]] ?? []
        return Failure(
            reason: errors.first?["reason"] as? String ?? "",
            message: error["message"] as? String ?? "")
    }

    /// The reasons Drive gives for a throttle.
    private static let throttleReasons: Set<String> = [
        "rateLimitExceeded", "userRateLimitExceeded", "sharingRateLimitExceeded",
        "quotaExceeded",
    ]

    /// One Drive failure onto one error kind of 8.4.
    ///
    /// A 403 alone says nothing, because Drive answers 403 for a full
    /// account, for a lost scope, and for a throttle. The reason
    /// decides, which is why 9.3 names the reasons rather than the
    /// codes.
    public static func error(
        status: Int,
        failure: Failure = Failure(reason: "", message: ""),
        retryAfterHeader: String? = nil,
        attempt: Int = 1
    ) -> BackupProviderError {
        switch status {
        case Status.unauthorized:
            return .authExpired
        case Status.tooManyRequests:
            return .throttled(retryAfter: retryAfterSeconds(retryAfterHeader, attempt: attempt))
        case Status.forbidden:
            return forbidden(failure, retryAfterHeader: retryAfterHeader, attempt: attempt)
        case Status.notFound, Status.gone:
            return .notFound
        case Status.serverError..<600:
            // Drive is up but unwell. 8.4 retries on the next pass.
            return .offline
        default:
            return .rejected(message: message(from: failure, status: status))
        }
    }

    private static func forbidden(
        _ failure: Failure, retryAfterHeader: String?, attempt: Int
    ) -> BackupProviderError {
        if failure.reason == "storageQuotaExceeded" { return .outOfSpace }
        if failure.reason == "insufficientPermissions" || failure.reason == "insufficientFilePermissions" {
            // A revoked scope. A re-sign-in does not fix it, so 8.4
            // blocks the target rather than asking for a sign-in.
            return .permissionDenied
        }
        if failure.reason == "authError" { return .authExpired }
        if throttleReasons.contains(failure.reason) {
            return .throttled(retryAfter: retryAfterSeconds(retryAfterHeader, attempt: attempt))
        }
        return .rejected(message: message(from: failure, status: Status.forbidden))
    }

    /// What a `rejected` shows the user, word for word, per 8.4.
    private static func message(from failure: Failure, status: Int) -> String {
        let text = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Google Drive answered \(status)" }
        return "Google Drive answered \(status): \(text)"
    }

    /// Whether Drive lost the session and the upload has to start
    /// again with a new session URI.
    ///
    /// A session URI lives one week, per 9.3. Drive answers 404 for
    /// one it no longer holds, and 410 for one that expired.
    public static func isSessionGone(status: Int) -> Bool {
        status == Status.notFound || status == Status.gone
    }
}

// MARK: - files.list

/// One file of a page, as Drive reports it.
public struct GoogleDriveFile: Equatable, Sendable {
    public let id: String
    /// The whole Empo path. Drive has no path model, so the name
    /// carries it, per the note on `GoogleDrive`.
    public let name: String
    public let sizeBytes: Int64
    public let modifiedTime: Date?
    public let mimeType: String

    public init(
        id: String, name: String, sizeBytes: Int64, modifiedTime: Date?, mimeType: String
    ) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime
        self.mimeType = mimeType
    }

    /// A folder holds no bytes, and 8.1 has no directory model, so
    /// only files reach `list`.
    public var isFile: Bool { mimeType != GoogleDrive.folderMimeType }
}

/// One page of `files.list`, per 9.3.
public struct GoogleDriveFilePage: Equatable, Sendable {
    public let files: [GoogleDriveFile]
    /// The token of the next page, or `nil` on the last one.
    public let nextPageToken: String?

    public init(files: [GoogleDriveFile], nextPageToken: String?) {
        self.files = files
        self.nextPageToken = nextPageToken
    }

    public var hasMore: Bool {
        guard let nextPageToken else { return false }
        return !nextPageToken.isEmpty
    }
}

extension GoogleDrive {

    /// Drive stamps `modifiedTime` in RFC 3339, with a fraction.
    public static func date(fromTimestamp text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Reads one `files.list` answer.
    public static func page(fromBody body: Data) -> GoogleDriveFilePage? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        let raw = root["files"] as? [[String: Any]] ?? []
        let files = raw.map { file in
            GoogleDriveFile(
                id: file["id"] as? String ?? "",
                name: file["name"] as? String ?? "",
                sizeBytes: int64(file["size"]) ?? 0,
                modifiedTime: (file["modifiedTime"] as? String).flatMap(date(fromTimestamp:)),
                mimeType: file["mimeType"] as? String ?? "")
        }
        return GoogleDriveFilePage(
            files: files, nextPageToken: root["nextPageToken"] as? String)
    }

    /// Every object of every page, as `list` reports them, per 8.1.
    ///
    /// Drive lists the whole folder and takes no prefix of its own,
    /// so the prefix filter runs here. The result is sorted, because
    /// 8.1 states a flat namespace and two callers compare two lists.
    public static func objects(
        fromPages pages: [GoogleDriveFilePage], prefix: String
    ) -> [RemoteObject] {
        var found: [RemoteObject] = []
        for page in pages {
            for file in page.files where file.isFile {
                guard file.name.hasPrefix(prefix) else { continue }
                found.append(
                    RemoteObject(
                        path: file.name,
                        sizeBytes: file.sizeBytes,
                        modifiedAt: file.modifiedTime))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The id and the name of every file of every page, which is what
    /// the path-to-id cache reads.
    public static func identifiers(
        fromPages pages: [GoogleDriveFilePage]
    ) -> [String: String] {
        var found: [String: String] = [:]
        for page in pages {
            for file in page.files where file.isFile && !file.id.isEmpty {
                found[file.name] = file.id
            }
        }
        return found
    }

    /// The id one answer names, from a create, an update, or a name
    /// query that found one file.
    public static func fileId(inBody body: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        if let id = root["id"] as? String, !id.isEmpty { return id }
        guard let files = root["files"] as? [[String: Any]] else { return nil }
        guard let id = files.first?["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    // MARK: - about.get

    /// What `about.get` with `fields=storageQuota` answers, per 9.3.
    ///
    /// Drive writes the numbers as strings. An account with no stated
    /// limit sends no `limit`, which `QuotaReading` already carries.
    public static func quota(fromBody body: Data) -> QuotaReading? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        guard let storage = root["storageQuota"] as? [String: Any] else { return nil }
        guard let used = int64(storage["usage"]) else { return nil }
        return QuotaReading(usedBytes: used, limitBytes: int64(storage["limit"]))
    }

    /// Drive sends a byte count as a string. An older field may send
    /// a number, so both read the same way.
    static func int64(_ value: Any?) -> Int64? {
        if let text = value as? String { return Int64(text) }
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }
}

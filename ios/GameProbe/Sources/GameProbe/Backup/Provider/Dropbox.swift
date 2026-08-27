import Foundation

/// The Dropbox rules of SPEC 9.2 that need no network.
///
/// The account needs a real sign-in, so the provider itself lives in
/// the app target. Everything a test can reach lives here: the
/// endpoints, the framing of an upload, the paging of a list, the
/// batch limit of a delete, and the map from a Dropbox failure onto
/// the seven error kinds of 8.4.
///
/// Empo hand-rolls this REST, per 9.2. SwiftyDropbox would bring a
/// second background-session stack beside Empo's own, and Empo calls
/// six endpoints.
public enum Dropbox {

    /// What the user sees in their Dropbox, per 9.2.
    ///
    /// App-folder access scopes every API path to this folder, so
    /// Empo never sends the name. The target descriptor carries an
    /// empty root and the layout of 5.1 starts at `Empo/` inside it.
    public static let displayRoot = "/Apps/Empo"

    /// The root the descriptor carries, per 8.7. It is empty because
    /// the app folder is already the root the token can reach.
    public static let root = ""

    public static let capabilities = TargetCapabilities(
        canQueryQuota: true,
        reportsObjectAge: true,
        supportsBackgroundTransfer: true,
        maxFileSize: Dropbox.maxFileSizeBytes,
        foldsCase: true)

    // MARK: - The endpoints

    /// The six endpoints of 9.2, and nothing else.
    public enum Endpoint: String, CaseIterable, Equatable, Sendable {
        case uploadSessionStart = "https://content.dropboxapi.com/2/files/upload_session/start"
        case uploadSessionAppend = "https://content.dropboxapi.com/2/files/upload_session/append_v2"
        case uploadSessionFinish = "https://content.dropboxapi.com/2/files/upload_session/finish"
        case upload = "https://content.dropboxapi.com/2/files/upload"
        case download = "https://content.dropboxapi.com/2/files/download"
        case listFolder = "https://api.dropboxapi.com/2/files/list_folder"
        case listFolderContinue = "https://api.dropboxapi.com/2/files/list_folder/continue"
        case deleteBatch = "https://api.dropboxapi.com/2/files/delete_batch"
        case deleteBatchCheck = "https://api.dropboxapi.com/2/files/delete_batch/check"
        case spaceUsage = "https://api.dropboxapi.com/2/users/get_space_usage"

        public var url: URL? { URL(string: rawValue) }
    }

    public static let authorizationEndpoint = "https://www.dropbox.com/oauth2/authorize"
    public static let tokenEndpoint = "https://api.dropboxapi.com/oauth2/token"

    /// The API path for one Empo path.
    ///
    /// Empo paths are flat and provider-relative, per 8.1. Dropbox
    /// wants a leading separator and no trailing one. The root of the
    /// app folder is the empty string, not `/`.
    public static func apiPath(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "" : "/" + trimmed
    }

    /// The Empo path for an API path, which is what `list` reports.
    public static func empoPath(forAPIPath path: String) -> String {
        String(path.drop(while: { $0 == "/" }))
    }

    /// The folder `list_folder` starts from for one prefix.
    ///
    /// Dropbox lists a folder and takes no prefix of its own, so the
    /// call starts at the deepest folder the prefix names and the
    /// caller filters what comes back. A prefix that ends with a
    /// separator already names a folder. One that does not names a
    /// file, or the start of a name, so its folder is the part before
    /// the last separator.
    public static func listFolder(forPrefix prefix: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix.hasSuffix("/") { return apiPath(for: trimmed) }
        guard let cut = trimmed.lastIndex(of: "/") else { return "" }
        return apiPath(for: String(trimmed[trimmed.startIndex..<cut]))
    }

    /// A JSON argument that is safe in an HTTP header.
    ///
    /// Dropbox takes the argument of a content call in
    /// `Dropbox-API-Arg`, and a header takes ASCII alone. Every name
    /// Empo writes is hex or fixed ASCII, per 5.2, so this changes
    /// nothing today and keeps a later name from breaking a request.
    public static func headerSafe(_ json: String) -> String {
        var out = ""
        for character in json.unicodeScalars {
            if character.isASCII && character.value >= 0x20 && character.value != 0x7F {
                out.unicodeScalars.append(character)
            } else {
                out += String(format: "\\u%04x", character.value)
            }
        }
        return out
    }

    // MARK: - Upload framing

    /// A single upload takes at most 150 MiB, per 9.2. Anything
    /// larger takes an upload session.
    public static let singleUploadLimitBytes: Int64 = 150 * 1024 * 1024

    /// About 2 TiB, per 9.2. The engine rejects a larger file before
    /// it moves a byte, through `TargetCapabilities.rejection`.
    public static let maxFileSizeBytes: Int64 = 2 * 1024 * 1024 * 1024 * 1024

    /// One append. A background URLSession uploads from a file, so
    /// every chunk becomes a file of its own on the way out. The size
    /// trades disk against the work a failed append repeats.
    public static let uploadChunkBytes: Int64 = 16 * 1024 * 1024

    /// An upload session stays valid for 7 days, per 9.2.
    public static let uploadSessionLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// One append of an upload session.
    public struct Chunk: Equatable, Sendable {
        public let offset: Int64
        public let length: Int64
        /// Whether `finish` commits after this one.
        public let isLast: Bool

        public init(offset: Int64, length: Int64, isLast: Bool) {
            self.offset = offset
            self.length = length
            self.isLast = isLast
        }

        public var endOffset: Int64 { offset + length }
    }

    /// How one file goes up, per 9.2.
    public enum UploadPlan: Equatable, Sendable {
        /// One `files/upload` call. Dropbox commits it whole, so it
        /// meets the atomicity promise of 8.2 on its own.
        case single
        /// `upload_session/start`, then an `append_v2` per chunk,
        /// then `finish`. Nothing appears at the path until the
        /// commit, which is how a session meets 8.2.
        case session(chunks: [Chunk])
    }

    public static func uploadPlan(forFileOfSize size: Int64) -> UploadPlan {
        guard size > singleUploadLimitBytes else { return .single }
        return .session(chunks: chunks(ofFileSize: size, from: 0))
    }

    /// The appends left for a file of this size, starting at
    /// `offset`.
    ///
    /// A session that broke resumes from the offset Dropbox reports,
    /// so it never restarts from zero. An offset at the end of the
    /// file leaves no append, and `finish` still has to run.
    public static func chunks(ofFileSize size: Int64, from offset: Int64) -> [Chunk] {
        let start = max(0, min(offset, size))
        guard start < size else { return [] }

        var chunks: [Chunk] = []
        var cursor = start
        while cursor < size {
            let length = min(uploadChunkBytes, size - cursor)
            cursor += length
            chunks.append(Chunk(offset: cursor - length, length: length, isLast: cursor >= size))
        }
        return chunks
    }

    // MARK: - Delete

    /// The most paths one `delete_batch` takes. Dropbox states 1000
    /// entries, and the engine can ask for more after a sweep.
    public static let deleteBatchLimit = 1000

    /// Splits a delete into batches the API takes.
    public static func deleteBatches(paths: [String]) -> [[String]] {
        guard !paths.isEmpty else { return [] }
        return stride(from: 0, to: paths.count, by: deleteBatchLimit).map {
            Array(paths[$0..<min($0 + deleteBatchLimit, paths.count)])
        }
    }

    // MARK: - The error map, per 8.4

    /// The HTTP codes Dropbox answers, named so the map below reads
    /// as the rule and not as a table of numbers.
    public enum Status {
        public static let ok = 200
        public static let badRequest = 400
        public static let invalidToken = 401
        public static let accessDenied = 403
        public static let endpointError = 409
        public static let tooManyRequests = 429
        public static let serverError = 500
        public static let serviceUnavailable = 503
    }

    /// The default wait when Dropbox throttles and states no time.
    public static let defaultRetryAfter: TimeInterval = 5

    /// `Retry-After` in seconds, per 8.6. A missing or unreadable
    /// header takes the default, because a throttle Empo ignores
    /// earns a second throttle.
    public static func retryAfterSeconds(_ header: String?) -> TimeInterval {
        guard let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
            seconds > 0
        else {
            return defaultRetryAfter
        }
        return seconds
    }

    /// One Dropbox failure onto one error kind of 8.4.
    ///
    /// Dropbox puts the endpoint's own reason in `error_summary`, so
    /// a 409 alone says nothing. The summary decides.
    public static func error(
        status: Int, errorSummary: String = "", retryAfterHeader: String? = nil
    ) -> BackupProviderError {
        switch status {
        case Status.invalidToken:
            return .authExpired
        case Status.tooManyRequests, Status.serviceUnavailable:
            return .throttled(retryAfter: retryAfterSeconds(retryAfterHeader))
        case Status.accessDenied:
            // A revoked scope. A re-sign-in does not fix it, so 8.4
            // blocks the target rather than asking for a sign-in.
            return .permissionDenied
        case Status.endpointError, Status.badRequest:
            return endpointError(summary: errorSummary)
        case Status.serverError..<600:
            // Dropbox is up but unwell. 8.4 retries on the next pass.
            return .offline
        default:
            return .rejected(message: message(fromSummary: errorSummary, status: status))
        }
    }

    /// The reason a 409 carries. Dropbox writes it as a slash-joined
    /// tag, such as `path/not_found/`.
    private static func endpointError(summary: String) -> BackupProviderError {
        let tags = summary.split(separator: "/").map(String.init)
        if tags.contains("insufficient_space") { return .outOfSpace }
        if tags.contains("not_found") || tags.contains("path_lookup") { return .notFound }
        if tags.contains("expired_access_token") || tags.contains("invalid_access_token") {
            return .authExpired
        }
        if tags.contains("no_write_permission") || tags.contains("team_folder") {
            return .permissionDenied
        }
        if tags.contains("too_many_write_operations") || tags.contains("too_many_requests") {
            return .throttled(retryAfter: defaultRetryAfter)
        }
        return .rejected(message: message(fromSummary: summary, status: Status.endpointError))
    }

    /// What a `rejected` shows the user, word for word, per 8.4.
    private static func message(fromSummary summary: String, status: Int) -> String {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Dropbox answered \(status)" }
        return "Dropbox answered \(status): \(text)"
    }

    /// The offset Dropbox wants when an append lands at the wrong
    /// one, or `nil` when the failure is something else.
    ///
    /// This is what lets a broken session resume from its cursor
    /// rather than from zero.
    public static func correctedOffset(inBody body: Data) -> Int64? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        guard let error = root["error"] as? [String: Any] else { return nil }
        guard error[".tag"] as? String == "incorrect_offset" else { return nil }
        return (error["correct_offset"] as? NSNumber)?.int64Value
    }

    /// The `error_summary` of a failure body, or an empty string.
    public static func errorSummary(inBody body: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ""
        }
        return root["error_summary"] as? String ?? ""
    }
}

// MARK: - list_folder

/// One page of `list_folder`, per 9.2.
public struct DropboxListPage: Equatable, Sendable {
    public let entries: [DropboxEntry]
    public let cursor: String
    public let hasMore: Bool

    public init(entries: [DropboxEntry], cursor: String, hasMore: Bool) {
        self.entries = entries
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

/// One entry of a page. Dropbox reports folders and deletions in the
/// same list, and 8.1 has no directory model, so only files survive.
public struct DropboxEntry: Equatable, Sendable {
    public let tag: String
    /// `path_display` keeps the case the account holds. `path_lower`
    /// does not, and Dropbox folds case, per 9.2.
    public let path: String
    public let sizeBytes: Int64
    public let serverModified: Date?

    public init(tag: String, path: String, sizeBytes: Int64, serverModified: Date?) {
        self.tag = tag
        self.path = path
        self.sizeBytes = sizeBytes
        self.serverModified = serverModified
    }

    public var isFile: Bool { tag == "file" }
}

extension Dropbox {

    /// Dropbox stamps `server_modified` in this form.
    public static let timestampFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"

    public static func date(fromTimestamp text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = timestampFormat
        return formatter.date(from: text)
    }

    /// Reads one `list_folder` or `list_folder/continue` answer.
    public static func page(fromBody body: Data) -> DropboxListPage? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        let raw = root["entries"] as? [[String: Any]] ?? []
        let entries = raw.map { entry in
            DropboxEntry(
                tag: entry[".tag"] as? String ?? "",
                path: entry["path_display"] as? String ?? entry["path_lower"] as? String ?? "",
                sizeBytes: (entry["size"] as? NSNumber)?.int64Value ?? 0,
                serverModified: (entry["server_modified"] as? String).flatMap(date(fromTimestamp:)))
        }
        return DropboxListPage(
            entries: entries,
            cursor: root["cursor"] as? String ?? "",
            hasMore: root["has_more"] as? Bool ?? false)
    }

    /// Every object of every page, as `list` reports them, per 8.1.
    ///
    /// Dropbox lists a whole folder, so the prefix filter runs here.
    /// The result is sorted, because 8.1 states a flat namespace and
    /// two callers compare two lists.
    public static func objects(
        fromPages pages: [DropboxListPage], prefix: String
    ) -> [RemoteObject] {
        var found: [RemoteObject] = []
        for page in pages {
            for entry in page.entries where entry.isFile {
                let path = empoPath(forAPIPath: entry.path)
                guard path.hasPrefix(prefix) else { continue }
                found.append(
                    RemoteObject(
                        path: path,
                        sizeBytes: entry.sizeBytes,
                        modifiedAt: entry.serverModified))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - users/get_space_usage

    /// What `users/get_space_usage` answers, per 9.2.
    ///
    /// A team account states its allocation under a second tag, and
    /// an account with no stated limit answers `nil` for the limit,
    /// which `QuotaReading` already carries.
    public static func quota(fromBody body: Data) -> QuotaReading? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        guard let used = (root["used"] as? NSNumber)?.int64Value else { return nil }
        let allocation = root["allocation"] as? [String: Any]
        let allocated = (allocation?["allocated"] as? NSNumber)?.int64Value
        return QuotaReading(usedBytes: used, limitBytes: allocated)
    }
}

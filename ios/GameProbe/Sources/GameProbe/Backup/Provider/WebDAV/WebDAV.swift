import Foundation

/// The WebDAV rules of SPEC 9.5 that need no network.
///
/// This is the second target the user hosts themselves. Raw HTTP
/// over URLSession carries it: `PROPFIND`, `PUT`, `GET`, `DELETE`,
/// `MKCOL`, and `MOVE`. No library is worth adopting for six
/// methods, per 9.5.
///
/// It is the first target whose capability flags differ per server
/// and not per provider. RFC 4331 states a space query, some servers
/// answer it, and others do not. So the add-time check of 8.7 asks
/// the server and writes the answer into `canQueryQuota`, per 9.7.
///
/// The rules a test can reach live here: the answer shapes of the
/// servers, the space query, the put sequence, the collections, and
/// the map from a WebDAV status onto the seven error kinds of 8.4.
/// `WebDAVServer` holds the address. The file work needs a server, so
/// it lives in the app.
public enum WebDAV {

    /// The five flags of 8.3, per 9.5 and 9.7.
    ///
    /// `answersQuota` comes from the permission check of 8.7, which
    /// asks the one server this target writes to. `maxFileSize` is
    /// `nil`, because the server sets the limit and states no number.
    public static func capabilities(answersQuota: Bool) -> TargetCapabilities {
        TargetCapabilities(
            canQueryQuota: answersQuota,
            reportsObjectAge: true,
            supportsBackgroundTransfer: true,
            maxFileSize: nil,
            foldsCase: false)
    }

    // MARK: - The six methods of 9.5

    public enum Method {
        public static let propfind = "PROPFIND"
        public static let put = "PUT"
        public static let get = "GET"
        public static let delete = "DELETE"
        public static let makeCollection = "MKCOL"
        public static let move = "MOVE"
    }

    /// `Depth` on the two `PROPFIND` calls Empo makes.
    ///
    /// A listing walks one collection at a time. `Depth: infinity` is
    /// the call that would read a whole tree at once, and Nextcloud
    /// refuses it, so Empo never sends it.
    public enum Depth {
        public static let one = "1"
        public static let zero = "0"
    }

    /// The properties a listing reads, per 9.5.
    public static let listPropertiesBody = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <propfind xmlns="DAV:"><prop>\
        <resourcetype/><getcontentlength/><getlastmodified/>\
        </prop></propfind>
        """.utf8)

    /// The two properties RFC 4331 states, per 9.5.
    public static let quotaPropertiesBody = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <propfind xmlns="DAV:"><prop>\
        <quota-available-bytes/><quota-used-bytes/>\
        </prop></propfind>
        """.utf8)

    // MARK: - The put sequence of 9.5

    /// What a staged upload is called while it goes up.
    ///
    /// It is a sibling of the file it becomes, so the `MOVE` stays
    /// inside one collection and the server renames rather than
    /// copies.
    public static let temporaryPrefix = ".empo-partial-"

    /// The temp name one path stages under, per 9.5.
    ///
    /// The name comes from the path and carries no random part. A
    /// `PUT` that failed leaves bytes behind, and the next attempt at
    /// the same path writes over the same name. A random name would
    /// leave one file per failed attempt, and the sweep of 5.11
    /// deletes a blob and never a name it cannot read.
    public static func temporaryPath(for path: String) -> String {
        let collection = collectionPath(ofPath: path)
        let name = lastSegment(ofPath: path)
        return BackupNamespacePaths.join(collection, temporaryPrefix + name)
    }

    /// Whether this path is a staged upload and not an object.
    ///
    /// `list` reports objects, per 8.1. A file that is still going up
    /// is not one yet.
    public static func isTemporaryPath(_ path: String) -> Bool {
        lastSegment(ofPath: path).hasPrefix(temporaryPrefix)
    }

    /// One step of a `put`, per 9.5 and 8.2.
    public enum PutStep: Equatable, Sendable {
        /// `PUT` the whole file under the temp name. The RFC states
        /// no resumable mode, so an interrupted `PUT` starts again
        /// from zero.
        case stage(path: String)
        /// `MOVE` the temp name over the target path. This is the
        /// commit of 8.2: until it answers, the path holds the old
        /// content.
        case commit(from: String, to: String)
    }

    /// How one file goes up, per 9.5.
    ///
    /// The engine has no `move` operation and it never renames a
    /// remote object, per 8.1. This rename lives inside `put`, where
    /// the engine cannot see it.
    public static func putSteps(path: String) -> [PutStep] {
        let temporary = temporaryPath(for: path)
        return [.stage(path: temporary), .commit(from: temporary, to: path)]
    }

    // MARK: - The collections

    /// Every collection that has to exist before a file at this path
    /// can, shallowest first.
    ///
    /// WebDAV has a directory model and the engine does not, per 8.1.
    /// A path the engine hands over names collections the server may
    /// never have seen, so `put` makes them.
    public static func ancestorCollections(ofPath path: String) -> [String] {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count > 1 else { return [] }
        var collections: [String] = []
        var climbed = ""
        for segment in segments.dropLast() {
            climbed = BackupNamespacePaths.join(climbed, segment)
            collections.append(climbed)
        }
        return collections
    }

    /// The collection one path sits in.
    public static func collectionPath(ofPath path: String) -> String {
        let trimmed = trimmingSeparators(path)
        guard let cut = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[trimmed.startIndex..<cut])
    }

    /// The collection a prefix reads from.
    ///
    /// A prefix that ends with a separator names a collection. Every
    /// other prefix names a file, or the start of a file name, so the
    /// walk begins at the collection that holds it.
    public static func collectionPath(ofPrefix prefix: String) -> String {
        prefix.hasSuffix("/") ? trimmingSeparators(prefix) : collectionPath(ofPath: prefix)
    }

    /// Whether a `MKCOL` found the collection already there.
    ///
    /// A server answers 405 when the path holds a collection, per
    /// RFC 4918. That is what makes the call idempotent: Empo asks
    /// for the root on every put and takes either answer.
    public static func collectionIsAlreadyThere(status: Int) -> Bool {
        status == Status.methodNotAllowed
    }

    /// Whether this answer means a collection on the way is missing.
    ///
    /// RFC 4918 states 409 for a `PUT` or a `MKCOL` whose parent
    /// collection does not exist. Some servers answer 404 instead, so
    /// both lead to the same repair.
    public static func needsACollection(status: Int) -> Bool {
        status == Status.conflict || status == Status.notFound
    }

    private static func trimmingSeparators(_ path: String) -> String {
        var text = path
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private static func lastSegment(ofPath path: String) -> String {
        String(trimmingSeparators(path).split(separator: "/").last ?? "")
    }

    // MARK: - Reading a multistatus answer

    /// One `<response>` of a multistatus answer, per RFC 4918.
    public struct Entry: Equatable, Sendable {
        /// The address the server named, as it wrote it. It is a path
        /// on some servers and a whole URL on others.
        public let href: String
        public let isCollection: Bool
        public let sizeBytes: Int64
        public let modifiedAt: Date?

        public init(href: String, isCollection: Bool, sizeBytes: Int64, modifiedAt: Date?) {
            self.href = href
            self.isCollection = isCollection
            self.sizeBytes = sizeBytes
            self.modifiedAt = modifiedAt
        }
    }

    /// The status one `<propstat>` carries, out of a line such as
    /// `HTTP/1.1 200 OK`.
    public static func status(ofLine line: String) -> Int? {
        for part in line.split(separator: " ") {
            if let number = Int(part), number >= 100, number < 600 { return number }
        }
        return nil
    }

    /// Every entry of a multistatus answer.
    ///
    /// A server answers one `<propstat>` per status. Nextcloud puts
    /// the properties it holds in the 200 block and the ones it does
    /// not in a 404 block beside it, so a reader that took both would
    /// read a property the server said it has not got. This reads the
    /// 2xx blocks alone.
    public static func entries(fromBody body: Data) -> [Entry] {
        guard let xml = String(data: body, encoding: .utf8) else { return [] }
        let dates = httpDateReader()
        return DAVXML.blocks("response", in: xml).compactMap { response in
            guard let href = DAVXML.value("href", in: response), !href.isEmpty else { return nil }
            let properties = foundProperties(in: response)
            return Entry(
                href: href,
                isCollection: DAVXML.has("collection", in: properties),
                sizeBytes: DAVXML.int64("getcontentlength", in: properties) ?? 0,
                modifiedAt: DAVXML.value("getlastmodified", in: properties)
                    .flatMap { dates($0) })
        }
    }

    /// The properties the server says it holds, joined into one text.
    private static func foundProperties(in response: String) -> String {
        let blocks = DAVXML.blocks("propstat", in: response)
        // A server that answers no `propstat` at all put the
        // properties straight in the response.
        guard !blocks.isEmpty else { return response }
        var found = ""
        for block in blocks {
            guard let line = DAVXML.value("status", in: block),
                let status = status(ofLine: line),
                (200..<300).contains(status)
            else { continue }
            found += DAVXML.blocks("prop", in: block).joined()
        }
        return found
    }

    /// The space query of RFC 4331, or `nil` where this server does
    /// not answer it, per 9.5 and 9.7.
    ///
    /// A `nil` is not an error. 13.6 states what the target screen
    /// shows in its place, and a target that answered once and later
    /// stops answering falls back to the same line.
    public static func quota(fromBody body: Data) -> QuotaReading? {
        guard let xml = String(data: body, encoding: .utf8) else { return nil }
        guard let response = DAVXML.blocks("response", in: xml).first else { return nil }
        let properties = foundProperties(in: response)
        guard let used = DAVXML.int64("quota-used-bytes", in: properties), used >= 0 else {
            return nil
        }
        // Nextcloud writes a negative number for a share with no
        // limit. RFC 4331 states no such value, so anything under
        // zero reads as "a use with no limit".
        let available = DAVXML.int64("quota-available-bytes", in: properties)
        guard let available, available >= 0 else {
            return QuotaReading(usedBytes: used, limitBytes: nil)
        }
        return QuotaReading(usedBytes: used, limitBytes: used + available)
    }

    /// Reads the `getlastmodified` of RFC 4918, which is an HTTP
    /// date. A few servers write an ISO 8601 stamp instead, so this
    /// takes that too.
    ///
    /// It hands back a function, because one listing holds hundreds
    /// of stamps and one formatter reads them all.
    public static func httpDateReader() -> (String) -> Date? {
        let http = DateFormatter()
        http.locale = Locale(identifier: "en_US_POSIX")
        http.timeZone = TimeZone(secondsFromGMT: 0)
        http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        return { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return http.date(from: trimmed) ?? iso.date(from: trimmed)
        }
    }

    // MARK: - Throttling, per 8.6

    /// The wait when the server throttles and states no time.
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

    /// `Retry-After` in seconds, per 8.6.
    ///
    /// HTTP states two forms, and a WebDAV server may send either: a
    /// count of seconds, or a date. The backoff covers the header a
    /// server leaves out.
    public static func retryAfterSeconds(
        _ header: String?, attempt: Int = 1, now: Date = Date()
    ) -> TimeInterval {
        guard let header else { return backoffSeconds(attempt: attempt) }
        let text = header.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(text), seconds > 0 { return seconds }
        if let date = httpDateReader()(text) {
            let wait = date.timeIntervalSince(now)
            if wait > 0 { return wait }
        }
        return backoffSeconds(attempt: attempt)
    }

    // MARK: - The error map, per 8.4

    /// The status codes, named so the map below reads as the rule.
    public enum Status {
        public static let ok = 200
        public static let created = 201
        public static let noContent = 204
        public static let multiStatus = 207
        public static let unauthorized = 401
        public static let forbidden = 403
        public static let notFound = 404
        /// A `MKCOL` on a collection that is already there.
        public static let methodNotAllowed = 405
        /// A `PUT` or a `MKCOL` whose parent collection is missing.
        public static let conflict = 409
        /// Another client holds a WebDAV lock on the path.
        public static let locked = 423
        public static let tooManyRequests = 429
        public static let serverError = 500
        /// The server does not do this method at all.
        public static let notImplemented = 501
        public static let unavailable = 503
        public static let insufficientStorage = 507
    }

    /// Whether this answer means the server does not do the space
    /// query of RFC 4331 at all, per 9.7.
    ///
    /// RFC 4918 asks a server to answer 207 and name the property it
    /// has not got, and `quota(fromBody:)` reads that. A server that
    /// refuses the request outright says the same thing in a blunter
    /// way, so the space query reports `nil` and no error.
    public static func hasNoSpaceQuery(status: Int) -> Bool {
        status == Status.methodNotAllowed || status == Status.notImplemented
    }

    /// One WebDAV answer onto one error kind of 8.4.
    public static func error(
        status: Int,
        body: Data = Data(),
        retryAfterHeader: String? = nil,
        attempt: Int = 1
    ) -> BackupProviderError {
        switch status {
        case Status.unauthorized:
            // The app password no longer works. A new one is what
            // needs-sign-in asks for.
            return .authExpired
        case Status.forbidden:
            // The password works and the rights do not cover the
            // call. A re-sign-in adds no right, so 8.4 blocks the
            // target.
            return .permissionDenied
        case Status.notFound:
            return .notFound
        case Status.locked:
            // Another client holds a lock. It is not Empo's to break,
            // and the user is the one who can clear it.
            return .rejected(message: message(fromBody: body, status: status))
        case Status.tooManyRequests, Status.unavailable:
            return .throttled(
                retryAfter: retryAfterSeconds(retryAfterHeader, attempt: attempt))
        case Status.insufficientStorage:
            return .outOfSpace
        case Status.serverError..<600:
            // The server is up but unwell. 8.4 retries on the next
            // pass.
            return .offline
        default:
            return .rejected(message: message(fromBody: body, status: status))
        }
    }

    /// What a `rejected` shows the user, word for word, per 8.4.
    ///
    /// A server that speaks WebDAV writes its reason in a `message`
    /// element. Apache `mod_dav` answers a page of HTML instead, and
    /// the status is then all there is to say.
    public static func message(fromBody body: Data, status: Int) -> String {
        let stated = "the server answered \(status)"
        guard let xml = String(data: body, encoding: .utf8) else { return stated }
        let said =
            DAVXML.value("message", in: xml) ?? DAVXML.value("responsedescription", in: xml) ?? ""
        guard !said.isEmpty else { return stated }
        return "\(stated): \(said)"
    }

    // MARK: - The add form of 13.7

    /// The fields the add form shows, and the one line beside the
    /// address, per 13.7. Ticket 016 builds the form.
    ///
    /// The address carries the warning of 5.7, because that is the
    /// moment the user types their own host name. It is the same
    /// copy the S3 form carries.
    public static let addFormFields: [TargetFormField] = [
        TargetFormField(name: "label", label: "Name", hint: "My server"),
        TargetFormField(
            name: "address", label: "Address",
            hint: "https://cloud.example.com/remote.php/dav/files/alice",
            note: TransportSecurity.storageWarning),
        TargetFormField(
            name: "root", label: "Folder on the server", hint: "empo", isRequired: false),
        TargetFormField(name: "username", label: "User name", hint: "alice"),
        TargetFormField(
            name: "password", label: "Password", hint: "", kind: .secret,
            note: "An app password of your server fits here."),
    ]
}

import Foundation
import GameProbe

/// The WebDAV target of SPEC 9.5, the second target the user hosts
/// themselves.
///
/// Raw HTTP over URLSession: `PROPFIND`, `PUT`, `GET`, `DELETE`,
/// `MKCOL`, and `MOVE`. No library ships for it, per 9.5. Auth is
/// HTTP Basic over TLS, and 8.11 takes system trust alone.
///
/// The rules a test can reach live in `WebDAV` and `WebDAVServer`,
/// inside GameProbe: the answer shapes of the servers, the space
/// query, the put sequence, the collections, and the error map. This
/// file needs a server.
///
/// **Two things set this target apart from the four before it.**
///
/// The server has a directory model and the engine has none, per 8.1.
/// A path the engine hands over names collections the server may
/// never have seen, so `put` makes them with `MKCOL` and takes the
/// 405 that says one is already there.
///
/// `PUT` is whole-file and the RFC states no resumable mode, so an
/// interrupted upload starts again from zero. Empo puts to a temp
/// name and commits with `MOVE`, which is how this provider meets the
/// atomicity promise of 8.2. The engine has no `move` operation and
/// never renames a remote object. The rename lives in here, where the
/// engine cannot see it.
actor WebDAVTarget: BackupProvider {

    nonisolated let capabilities: TargetCapabilities

    private let connection: WebDAVConnection
    private let gate = TransferGate()

    /// Every path this process committed. A `MOVE` answers only after
    /// the server holds the file, so a committed path is durable, per
    /// 8.5.
    private var committed: Set<String> = []

    /// Every collection this process has seen or made. `MKCOL` is
    /// idempotent, and this keeps a run from asking again for each of
    /// the thousands of blobs under one collection.
    private var knownCollections: Set<String> = []

    /// How many times running the server has throttled this target.
    /// The truncated backoff of 8.6 reads it, and a call that
    /// succeeds puts it back to one.
    private var throttleAttempt = 1

    init(connection: WebDAVConnection) {
        self.connection = connection
        self.capabilities = WebDAV.capabilities(answersQuota: connection.server.answersQuota)
    }

    private var server: WebDAVServer { connection.server }

    // MARK: - The six operations

    func list(prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        try await gate.request { () async throws(BackupProviderError) -> [RemoteObject] in
            try await self.walk(prefix: prefix)
        }
    }

    func put(localFile: URL, path: String) async throws(BackupProviderError) {
        // Before any byte moves, per 8.3. A WebDAV server states no
        // number, so this refuses nothing today. It stays because the
        // engine calls every provider the same way.
        let size = Self.fileSize(at: localFile)
        if let rejection = capabilities.rejection(forFileOfSize: size) { throw rejection }

        try await gate.transfer { () async throws(BackupProviderError) in
            try await self.stageAndCommit(localFile, to: path)
        }
        committed.insert(path)
    }

    /// Whether the object is durable, per 8.5.
    ///
    /// A `MOVE` answers only after the server holds the file, so a
    /// `put` that returned is already durable. A new process holds no
    /// record of that, and one `PROPFIND` tells it.
    func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation {
        if committed.contains(path) { return .confirmed }
        return try await gate.request { () async throws(BackupProviderError) -> PutConfirmation in
            try await self.propfindOne(path)
        }
    }

    func get(path: String, localFile: URL) async throws(BackupProviderError) {
        try await gate.transfer { () async throws(BackupProviderError) in
            try await self.getOne(path, to: localFile)
        }
    }

    func delete(paths: [String]) async throws(BackupProviderError) {
        // One `DELETE` per path. WebDAV states no batch delete, and a
        // prune deletes tens of paths, not thousands.
        for path in paths {
            try await gate.request { () async throws(BackupProviderError) in
                try await self.deleteOne(path)
            }
        }
    }

    private func propfindOne(
        _ path: String
    ) async throws(BackupProviderError) -> PutConfirmation {
        let answer = try await send(
            WebDAV.Method.propfind, path: path,
            headers: ["Depth": WebDAV.Depth.zero],
            body: WebDAV.listPropertiesBody)
        try check(answer)
        committed.insert(path)
        return .confirmed
    }

    private func getOne(
        _ path: String, to localFile: URL
    ) async throws(BackupProviderError) {
        let request = try makeRequest(WebDAV.Method.get, path: path)
        let answer = try await BackupAPISession.shared.download(request, to: localFile)
        try check(answer)
    }

    private func deleteOne(_ path: String) async throws(BackupProviderError) {
        let answer = try await send(WebDAV.Method.delete, path: path)
        // A path that holds no file is not an error, per 8.1. The
        // delete has already got what it asked for.
        guard answer.isSuccess || answer.status == WebDAV.Status.notFound else {
            throw mapped(answer)
        }
        throttleAttempt = 1
        committed.remove(path)
    }

    /// The space query of RFC 4331, or `nil` where this server does
    /// not answer it, per 9.5 and 9.7.
    ///
    /// It asks the server on every call. The stored flag decides
    /// whether the engine asks at all, and this decides what the
    /// server said today. A server that answered at add time and
    /// stops answering later reports `nil` and no error, per 13.6.
    func quota() async throws(BackupProviderError) -> QuotaReading? {
        try await gate.request { () async throws(BackupProviderError) -> QuotaReading? in
            try await self.readQuota()
        }
    }

    private func readQuota() async throws(BackupProviderError) -> QuotaReading? {
        let answer = try await send(
            WebDAV.Method.propfind, path: "",
            headers: ["Depth": WebDAV.Depth.zero],
            body: WebDAV.quotaPropertiesBody)
        // A server that refuses the call is a server that does not
        // do RFC 4331, per 9.7. It is not a failure.
        if WebDAV.hasNoSpaceQuery(status: answer.status) { return nil }
        try check(answer)
        return WebDAV.quota(fromBody: answer.body)
    }

    // MARK: - The listing walk of 9.5

    /// Every object whose path starts with `prefix`.
    ///
    /// `Depth: infinity` would read a whole tree in one call, and
    /// Nextcloud refuses it, so the walk asks one collection at a
    /// time with `Depth: 1`.
    private func walk(prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        var found: [RemoteObject] = []
        var left = [WebDAV.collectionPath(ofPrefix: prefix)]
        var seen = Set<String>()

        while let collection = left.popLast() {
            guard seen.insert(collection).inserted else { continue }
            let answer = try await send(
                WebDAV.Method.propfind, path: collection,
                headers: ["Depth": WebDAV.Depth.one],
                body: WebDAV.listPropertiesBody)
            // A collection that is not there holds no object, and the
            // caller asked what is under it, not whether it exists.
            if answer.status == WebDAV.Status.notFound { continue }
            try check(answer)

            let entries = WebDAV.entries(fromBody: answer.body)
            found += server.objects(fromEntries: entries)
                .filter { $0.path.hasPrefix(prefix) }
            left += server.collections(fromEntries: entries, under: collection)
                .filter { $0.hasPrefix(prefix) || prefix.hasPrefix($0) }
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - The put of 9.5

    /// The temp name, then the `MOVE` that commits it, per 9.5 and
    /// 8.2.
    ///
    /// The path holds the old content until the `MOVE` answers. A
    /// `PUT` that dies part way leaves bytes under the temp name
    /// alone, and the next attempt writes over them from zero.
    private func stageAndCommit(
        _ localFile: URL, to path: String
    ) async throws(BackupProviderError) {
        var staged: String?
        do {
            for step in WebDAV.putSteps(path: path) {
                switch step {
                case .stage(let temporary):
                    staged = temporary
                    try await stage(localFile, at: temporary)
                case .commit(let from, let to):
                    try await commit(from: from, to: to)
                    staged = nil
                }
            }
        } catch {
            // The bytes under the temp name are of no use to anybody
            // now. A later attempt writes over them, and this saves
            // the room in the meantime.
            if let staged { await discard(staged) }
            throw error
        }
    }

    /// `PUT` the whole file under the temp name, on the background
    /// session of 7.3.
    private func stage(
        _ localFile: URL, at temporary: String
    ) async throws(BackupProviderError) {
        var answer = try await upload(localFile, to: temporary)
        if WebDAV.needsACollection(status: answer.status) {
            try await makeCollections(forPath: temporary)
            answer = try await upload(localFile, to: temporary)
        }
        try check(answer)
    }

    private func upload(
        _ localFile: URL, to path: String
    ) async throws(BackupProviderError) -> HTTPAnswer {
        let request = try makeRequest(WebDAV.Method.put, path: path)
        return try await BackupTransferSession.shared.upload(
            file: localFile, request: request, path: path)
    }

    /// `MOVE`, which is the commit of 8.2.
    private func commit(from: String, to: String) async throws(BackupProviderError) {
        guard let destination = server.url(path: to) else {
            throw BackupProviderError.rejected(message: "Empo built no address for the server")
        }
        let headers = [
            "Destination": destination.absoluteString,
            // The path may hold an older snapshot's file. The commit
            // replaces it, per 8.2.
            "Overwrite": "T",
        ]
        var answer = try await send(WebDAV.Method.move, path: from, headers: headers)
        if WebDAV.needsACollection(status: answer.status) {
            try await makeCollections(forPath: to)
            answer = try await send(WebDAV.Method.move, path: from, headers: headers)
        }
        try check(answer)
    }

    /// Drops a staged upload that will never commit. It reports
    /// nothing, because the caller is already on its way out with the
    /// failure that brought it here.
    private func discard(_ temporary: String) async {
        _ = try? await send(WebDAV.Method.delete, path: temporary)
    }

    // MARK: - The collections

    /// Makes every collection this path needs, shallowest first.
    ///
    /// `MKCOL` answers 405 when the collection is already there, so
    /// the call is idempotent and two devices cannot race each other
    /// into a failure.
    private func makeCollections(forPath path: String) async throws(BackupProviderError) {
        for collection in WebDAV.ancestorCollections(ofPath: path) {
            guard !knownCollections.contains(collection) else { continue }
            let answer = try await send(WebDAV.Method.makeCollection, path: collection)
            guard answer.isSuccess || WebDAV.collectionIsAlreadyThere(status: answer.status) else {
                throw mapped(answer)
            }
            knownCollections.insert(collection)
        }
        throttleAttempt = 1
    }

    // MARK: - The requests

    /// One request against this server, signed with HTTP Basic, per
    /// 9.5.
    private func makeRequest(
        _ method: String, path: String, headers: [String: String] = [:]
    ) throws(BackupProviderError) -> URLRequest {
        // Before the first byte leaves the device, so a plain `http`
        // address never carries the password, per 8.11.
        if let refusal = server.refusal { throw refusal }
        guard let url = server.url(path: path) else {
            throw BackupProviderError.rejected(message: "Empo built no address for the server")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func send(
        _ method: String, path: String, headers: [String: String] = [:], body: Data? = nil
    ) async throws(BackupProviderError) -> HTTPAnswer {
        var request = try makeRequest(method, path: path, headers: headers)
        if let body {
            request.httpBody = body
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return try await BackupAPISession.shared.send(request)
    }

    // MARK: - The answers

    private func check(_ answer: HTTPAnswer) throws(BackupProviderError) {
        guard answer.isSuccess else { throw mapped(answer) }
        throttleAttempt = 1
    }

    /// One WebDAV answer onto one error kind of 8.4, with the
    /// truncated backoff of 8.6 on a throttle.
    private func mapped(_ answer: HTTPAnswer) -> BackupProviderError {
        let error = WebDAV.error(
            status: answer.status,
            body: answer.body,
            retryAfterHeader: answer.retryAfterHeader,
            attempt: throttleAttempt)
        if case .throttled = error {
            throttleAttempt += 1
        } else {
            throttleAttempt = 1
        }
        return error
    }

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

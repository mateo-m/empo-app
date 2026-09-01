import Foundation
import GameProbe

/// The Google Drive target of SPEC 9.3, the second OAuth provider.
///
/// Hand-rolled REST over the one background session of 7.3, with the
/// AppAuth sign-in ticket 009 built. There is one OAuth stack and one
/// background session in the app, and this file adds neither.
///
/// The rules a test can reach live in `GoogleDrive`, inside GameProbe:
/// the URLs, the queries, the framing, the paging, and the error map.
/// This file needs an account.
///
/// **Drive has no path model.** Every object is a direct child of the
/// `Empo Backups` folder and its Drive name is the whole Empo path,
/// which is what 8.1 asks for. Two caches carry the cost of that: the
/// id of the root folder, and the id of each path Empo has seen. A
/// cold process fills the second one from the first `list`.
actor GoogleDriveTarget: BackupProvider {

    nonisolated let capabilities = GoogleDrive.capabilities

    private let tokens: OAuthTokenStore
    private let gate = TransferGate()

    /// Every path this process committed. Drive commits an upload
    /// before it answers, so a committed path is durable, per 8.5.
    private var committed: Set<String> = []

    /// The id of the `Empo Backups` folder of 9.3.
    private var rootFolder: String?

    /// The Drive id of each path this process has seen. An update
    /// needs it, because a create with a name Drive already holds
    /// makes a second file rather than replacing the first.
    private var identifiers: [String: String] = [:]

    /// How many times running Drive has throttled this target. The
    /// truncated backoff of 9.3 reads it, and a call that succeeds
    /// puts it back to one.
    private var throttleAttempt = 1

    init(tokens: OAuthTokenStore) {
        self.tokens = tokens
    }

    // MARK: - The six operations

    func list(prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        try await gate.request { () async throws(BackupProviderError) -> [RemoteObject] in
            try await self.everyPage(under: prefix)
        }
    }

    func put(localFile: URL, path: String) async throws(BackupProviderError) {
        // Before any byte moves, per 8.3. A file over the limit is a
        // permanent refusal and no amount of space makes it fit.
        let size = UploadStaging.fileSize(at: localFile)
        if let rejection = capabilities.rejection(forFileOfSize: size) { throw rejection }

        try await gate.transfer { () async throws(BackupProviderError) in
            switch GoogleDrive.uploadPlan(forFileOfSize: size) {
            case .simple:
                try await self.uploadWhole(localFile, to: path)
            case .resumable:
                try await self.uploadResumable(localFile, to: path, size: size)
            }
        }
        committed.insert(path)
    }

    /// Whether the object is durable, per 8.5.
    ///
    /// Drive commits before it answers, so a `put` that returned is
    /// already durable. A new process holds no record of that, and
    /// the list is what tells it.
    func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation {
        if committed.contains(path) { return .confirmed }
        let objects = try await list(prefix: path)
        guard objects.contains(where: { $0.path == path }) else {
            throw BackupProviderError.notFound
        }
        committed.insert(path)
        return .confirmed
    }

    func get(path: String, localFile: URL) async throws(BackupProviderError) {
        try await gate.transfer { () async throws(BackupProviderError) in
            guard let id = try await self.identifier(forPath: path) else {
                throw BackupProviderError.notFound
            }
            guard let url = GoogleDrive.filesURL(id: id, alt: "media") else {
                throw BackupProviderError.rejected(message: "Empo built no Google Drive URL")
            }
            let answer = try await BackupAPISession.shared.download(
                try await self.authorized(url), to: localFile)
            try await self.check(answer)
        }
    }

    func delete(paths: [String]) async throws(BackupProviderError) {
        for path in paths {
            try await gate.request { () async throws(BackupProviderError) in
                try await self.deleteOne(path)
            }
        }
    }

    /// The used bytes and the limit, per 9.3. Drive answers a space
    /// query, so `canQueryQuota` is true.
    func quota() async throws(BackupProviderError) -> QuotaReading? {
        try await gate.request { () async throws(BackupProviderError) -> QuotaReading? in
            guard let url = GoogleDrive.aboutURL() else {
                throw BackupProviderError.rejected(message: "Empo built no Google Drive URL")
            }
            let answer = try await BackupAPISession.shared.send(try await self.authorized(url))
            try await self.check(answer)
            return GoogleDrive.quota(fromBody: answer.body)
        }
    }

    // MARK: - The root folder

    /// The id of the `Empo Backups` folder, per 9.3. It creates the
    /// folder on the first call that finds none.
    ///
    /// Under `drive.file` the query answers only files this OAuth
    /// client created, so it names no parent. The user may have moved
    /// the folder somewhere else in their Drive, and it still counts.
    private func rootFolderId() async throws(BackupProviderError) -> String {
        if let rootFolder { return rootFolder }

        guard let listURL = GoogleDrive.filesListURL(query: GoogleDrive.rootFolderQuery()) else {
            throw BackupProviderError.rejected(message: "Empo built no Google Drive URL")
        }
        let found = try await BackupAPISession.shared.send(try await authorized(listURL))
        try check(found)
        if let id = GoogleDrive.fileId(inBody: found.body) {
            BackupLog.line("GoogleDriveTarget", "the grant already holds the folder \(id)")
            rootFolder = id
            return id
        }

        // Section 14 asks whether a fresh grant on a second device
        // still sees this folder. These two lines answer it: a second
        // device that logs a create made a second folder, so the
        // scope belongs to the install and not to the client.
        BackupLog.line("GoogleDriveTarget", "this grant sees no folder, so it creates one")

        guard let createURL = GoogleDrive.filesURL() else {
            throw BackupProviderError.rejected(message: "Empo built no Google Drive URL")
        }
        var request = try await authorized(createURL)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(GoogleDrive.folderMetadata().utf8)

        let created = try await BackupAPISession.shared.send(request)
        try check(created)
        guard let id = GoogleDrive.fileId(inBody: created.body) else {
            throw BackupProviderError.rejected(
                message: "Google Drive made no \(GoogleDrive.rootFolderName) folder")
        }
        rootFolder = id
        return id
    }

    // MARK: - files.list

    private func everyPage(under prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        let parent = try await rootFolderId()
        let query = GoogleDrive.childrenQuery(parentId: parent)

        var pages: [GoogleDriveFilePage] = []
        var pageToken: String?
        while true {
            guard let url = GoogleDrive.filesListURL(query: query, pageToken: pageToken) else {
                throw BackupProviderError.rejected(message: "Empo built no Google Drive URL")
            }
            let answer = try await BackupAPISession.shared.send(try await authorized(url))
            guard answer.isSuccess else {
                // A folder that is not there holds no object, and 8.1
                // says an empty answer, not an error.
                let error = mapped(answer)
                if error == .notFound { return [] }
                throw error
            }
            throttleAttempt = 1
            guard let page = GoogleDrive.page(fromBody: answer.body) else {
                throw BackupProviderError.rejected(
                    message: "Google Drive sent a page Empo cannot read")
            }
            pages.append(page)
            guard page.hasMore, let next = page.nextPageToken else { break }
            pageToken = next
        }

        // The list is the one call that names every path and its id
        // at once. A later `put` then needs no name query of its own.
        identifiers.merge(GoogleDrive.identifiers(fromPages: pages)) { _, fresh in fresh }
        return GoogleDrive.objects(fromPages: pages, prefix: prefix)
    }

    /// The Drive id of one path, or `nil` where the target holds no
    /// object there.
    private func identifier(forPath path: String) async throws(BackupProviderError) -> String? {
        if let cached = identifiers[path] { return cached }

        let parent = try await rootFolderId()
        guard
            let url = GoogleDrive.filesListURL(
                query: GoogleDrive.nameQuery(name: path, parentId: parent))
        else {
            throw BackupProviderError.rejected(message: "Empo built no Google Drive URL")
        }
        let answer = try await BackupAPISession.shared.send(try await authorized(url))
        try check(answer)
        guard let id = GoogleDrive.fileId(inBody: answer.body) else { return nil }
        identifiers[path] = id
        return id
    }

    // MARK: - The simple upload

    /// One `multipart/related` request, for a file up to 5 MB, per
    /// 9.3. Drive commits it whole, which meets 8.2.
    private func uploadWhole(_ localFile: URL, to path: String) async throws(BackupProviderError) {
        let parent = try await rootFolderId()
        let existing = try await identifier(forPath: path)

        let scratch = UploadStaging.scratchDirectory("google-drive")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let boundary = GoogleDrive.multipartBoundary()
        // An update keeps the name and the parent it already has, so
        // it sends the content alone.
        let metadata =
            existing == nil
            ? GoogleDrive.metadata(name: path, parentId: parent) : "{}"
        let body = scratch.appendingPathComponent("multipart")
        try UploadStaging.write(
            head: GoogleDrive.multipartHead(metadata: metadata, boundary: boundary),
            contentsOf: localFile,
            tail: GoogleDrive.multipartTail(boundary: boundary),
            to: body)

        guard let url = GoogleDrive.uploadURL(uploadType: "multipart", fileId: existing) else {
            throw BackupProviderError.rejected(message: "Empo built no Google Drive URL")
        }
        var request = try await authorized(url)
        request.httpMethod = existing == nil ? "POST" : "PATCH"
        request.setValue(
            GoogleDrive.multipartContentType(boundary: boundary),
            forHTTPHeaderField: "Content-Type")

        let answer = try await BackupTransferSession.shared.upload(
            file: body, request: request, path: path)
        try check(answer)
        remember(path: path, body: answer.body)
    }

    // MARK: - The resumable upload

    /// The session path of 9.3. Nothing appears at the path until the
    /// session ends, which is how this meets 8.2.
    private func uploadResumable(
        _ localFile: URL, to path: String, size: Int64
    ) async throws(BackupProviderError) {
        let scratch = UploadStaging.scratchDirectory("google-drive")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = GoogleDriveUploadSessionStore.shared
        let existing = try await identifier(forPath: path)
        var sessionURI: String
        var offset: Int64 = 0
        var startedAt = Date()

        // A chunked upload needs the app to run code between chunks,
        // and iOS ends a suspended app whenever it wants. Carry on
        // from the cursor the last process wrote, per 9.3.
        let saved = await store.session(forPath: path, fileSize: size)
        // The cursor on disk may be one chunk behind what Drive took,
        // so the probe of 9.3 decides where to carry on. A probe that
        // answers nil means Drive dropped the session.
        if let saved,
            let reached = try await probe(
                sessionURI: saved.sessionURI, fileSize: size)
        {
            sessionURI = saved.sessionURI
            offset = reached
            startedAt = saved.startedAt
            BackupLog.line(
                "GoogleDriveTarget", "the upload carries on from \(offset) of \(size) bytes")
        } else {
            if saved != nil { await store.forget(path: path) }
            sessionURI = try await startSession(path: path, size: size, fileId: existing)
        }

        var left = GoogleDrive.chunks(ofFileSize: size, from: offset)
        var finished: Data?
        while let chunk = left.first {
            let piece = try UploadStaging.piece(
                of: localFile, offset: chunk.offset, length: chunk.length,
                named: "chunk-\(chunk.offset)", in: scratch)
            defer { try? FileManager.default.removeItem(at: piece) }

            let answer = try await send(
                chunk: chunk, of: piece, sessionURI: sessionURI, path: path, fileSize: size)

            if answer.isSuccess {
                throttleAttempt = 1
                finished = answer.body
                left.removeFirst()
                continue
            }
            if answer.status == GoogleDrive.Status.resumeIncomplete {
                throttleAttempt = 1
                // Drive states how far it really got. Trusting the
                // local cursor would send a chunk it drops.
                offset = GoogleDrive.resumeOffset(fromRangeHeader: answer.header("Range"))
                await store.remember(
                    GoogleDriveUploadSession(
                        sessionURI: sessionURI, offset: offset, fileSize: size,
                        startedAt: startedAt),
                    forPath: path)
                left = GoogleDrive.chunks(ofFileSize: size, from: offset)
                continue
            }
            // A session URI Drive no longer holds is gone, and every
            // byte with it. Drop the cursor and open a new session.
            guard GoogleDrive.isSessionGone(status: answer.status) else { throw mapped(answer) }

            await store.forget(path: path)
            sessionURI = try await startSession(path: path, size: size, fileId: existing)
            startedAt = Date()
            left = GoogleDrive.chunks(ofFileSize: size, from: 0)
        }

        // The last chunk is the commit, so the cursor names nothing
        // now.
        await store.forget(path: path)
        guard let finished else {
            throw BackupProviderError.rejected(message: "Google Drive committed no file")
        }
        remember(path: path, body: finished)
    }

    /// Opens a session and answers its URI, per 9.3.
    private func startSession(
        path: String, size: Int64, fileId: String?
    ) async throws(BackupProviderError) -> String {
        let parent = try await rootFolderId()
        guard let url = GoogleDrive.uploadURL(uploadType: "resumable", fileId: fileId) else {
            throw BackupProviderError.rejected(message: "Empo built no Google Drive URL")
        }
        var request = try await authorized(url)
        request.httpMethod = fileId == nil ? "POST" : "PATCH"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = Data(
            (fileId == nil ? GoogleDrive.metadata(name: path, parentId: parent) : "{}").utf8)

        let answer = try await BackupAPISession.shared.send(request)
        try check(answer)
        guard let location = answer.header("Location"), !location.isEmpty else {
            throw BackupProviderError.rejected(message: "Google Drive opened no upload session")
        }
        return location
    }

    /// Asks Drive how far a session got, per 9.3.
    ///
    /// It answers the offset to carry on from, or `nil` when Drive no
    /// longer holds the session and the upload has to start again.
    private func probe(
        sessionURI: String, fileSize: Int64
    ) async throws(BackupProviderError) -> Int64? {
        guard let url = URL(string: sessionURI) else { return nil }
        var request = try await authorized(url)
        request.httpMethod = "PUT"
        request.setValue(
            GoogleDrive.probeContentRange(fileSize: fileSize),
            forHTTPHeaderField: "Content-Range")

        let answer = try await BackupAPISession.shared.send(request)
        if answer.status == GoogleDrive.Status.resumeIncomplete {
            return GoogleDrive.resumeOffset(fromRangeHeader: answer.header("Range"))
        }
        // The session already ended, so every byte is there.
        if answer.isSuccess { return fileSize }
        guard GoogleDrive.isSessionGone(status: answer.status) else { throw mapped(answer) }
        return nil
    }

    /// Sends one chunk. It rides the background session, because it
    /// carries a file and it has to survive suspension.
    private func send(
        chunk: GoogleDrive.Chunk, of piece: URL, sessionURI: String, path: String, fileSize: Int64
    ) async throws(BackupProviderError) -> HTTPAnswer {
        guard let url = URL(string: sessionURI) else {
            throw BackupProviderError.rejected(message: "Google Drive sent no session URI")
        }
        var request = try await authorized(url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(
            GoogleDrive.contentRange(of: chunk, fileSize: fileSize),
            forHTTPHeaderField: "Content-Range")
        return try await BackupTransferSession.shared.upload(
            file: piece, request: request, path: path)
    }

    // MARK: - Delete

    private func deleteOne(_ path: String) async throws(BackupProviderError) {
        guard let id = try await identifier(forPath: path) else {
            // The path holds no object, and the delete has already
            // got what it asked for, per 8.1.
            return
        }
        guard let url = GoogleDrive.filesURL(id: id) else {
            throw BackupProviderError.rejected(message: "Empo built no Google Drive URL")
        }
        var request = try await authorized(url)
        request.httpMethod = "DELETE"

        let answer = try await BackupAPISession.shared.send(request)
        // Drive answers 204 for a delete that worked. A 404 means
        // someone else already deleted it, which is the same end.
        guard answer.isSuccess || answer.status == GoogleDrive.Status.notFound else {
            throw mapped(answer)
        }
        throttleAttempt = 1
        identifiers[path] = nil
        committed.remove(path)
    }

    // MARK: - The requests

    private func authorized(_ url: URL) async throws(BackupProviderError) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(
            "Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Keeps the id of a path a create or an update just answered, so
    /// the next `put` of the same path updates rather than making a
    /// second file with the same name.
    private func remember(path: String, body: Data) {
        guard let id = GoogleDrive.fileId(inBody: body) else { return }
        identifiers[path] = id
    }

    private func check(_ answer: HTTPAnswer) throws(BackupProviderError) {
        guard answer.isSuccess else { throw mapped(answer) }
        throttleAttempt = 1
    }

    /// One Drive answer onto one error kind of 8.4, with the
    /// truncated backoff of 9.3 on a throttle.
    private func mapped(_ answer: HTTPAnswer) -> BackupProviderError {
        let error = GoogleDrive.error(
            status: answer.status,
            failure: GoogleDrive.failure(inBody: answer.body),
            retryAfterHeader: answer.retryAfterHeader,
            attempt: throttleAttempt)
        if case .throttled = error {
            throttleAttempt += 1
        } else {
            throttleAttempt = 1
        }
        return error
    }
}

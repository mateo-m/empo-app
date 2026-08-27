import Foundation
import GameProbe

/// The Dropbox target of SPEC 9.2, the first OAuth provider.
///
/// Hand-rolled REST over the one background session of 7.3, with
/// AppAuth for the sign-in. 9.2 bends the standing preference for
/// proven libraries on purpose: SwiftyDropbox would bring a second
/// background-session stack beside Empo's own, for six endpoints.
///
/// The rules a test can reach live in `Dropbox`, inside GameProbe:
/// the framing, the paging, the batch limit, and the error map. This
/// file needs an account.
///
/// App-folder access scopes every path to `/Apps/Empo`, so the target
/// sees nothing else in the account and the descriptor carries an
/// empty root.
actor DropboxTarget: BackupProvider {

    nonisolated let capabilities = Dropbox.capabilities

    private let tokens: OAuthTokenStore
    private let gate = TransferGate()

    /// Every path this process committed. Dropbox commits an upload
    /// before it answers, so a committed path is durable, per 8.5.
    private var committed: Set<String> = []

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
        let size = Self.fileSize(at: localFile)
        if let rejection = capabilities.rejection(forFileOfSize: size) { throw rejection }

        try await gate.transfer { () async throws(BackupProviderError) in
            switch Dropbox.uploadPlan(forFileOfSize: size) {
            case .single:
                try await self.uploadWhole(localFile, to: path)
            case .session(let chunks):
                try await self.uploadSession(localFile, to: path, size: size, chunks: chunks)
            }
        }
        committed.insert(path)
    }

    /// Whether the object is durable, per 8.5.
    ///
    /// Dropbox commits before it answers, so a `put` that returned is
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
            let argument = Self.json(["path": Dropbox.apiPath(for: path)])
            var request = try await self.contentRequest(.download, argument: argument)
            // A download sends no body, and Dropbox refuses a content
            // type it did not ask for.
            request.setValue(nil, forHTTPHeaderField: "Content-Type")

            let answer = try await BackupAPISession.shared.download(request, to: localFile)
            guard answer.isSuccess else { throw Self.error(answer) }
        }
    }

    func delete(paths: [String]) async throws(BackupProviderError) {
        for batch in Dropbox.deleteBatches(paths: paths) {
            try await gate.request { () async throws(BackupProviderError) in
                try await self.deleteOneBatch(batch)
            }
            for path in batch { committed.remove(path) }
        }
    }

    /// The used bytes and the limit, per 9.2. Dropbox answers a space
    /// query, so `canQueryQuota` is true.
    func quota() async throws(BackupProviderError) -> QuotaReading? {
        try await gate.request { () async throws(BackupProviderError) -> QuotaReading? in
            // The endpoint takes no argument and refuses a body.
            var request = try await self.apiRequest(.spaceUsage)
            request.httpBody = nil
            request.setValue(nil, forHTTPHeaderField: "Content-Type")

            let answer = try await BackupAPISession.shared.send(request)
            guard answer.isSuccess else { throw Self.error(answer) }
            return Dropbox.quota(fromBody: answer.body)
        }
    }

    // MARK: - list_folder

    private func everyPage(under prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        var pages: [DropboxListPage] = []
        var request = try await apiRequest(.listFolder)
        request.httpBody = Data(
            Self.json([
                "path": Dropbox.listFolder(forPrefix: prefix),
                "recursive": true,
                "include_deleted": false,
            ]).utf8)

        while true {
            let answer = try await BackupAPISession.shared.send(request)
            guard answer.isSuccess else {
                // A folder that is not there holds no object, and 8.1
                // says an empty answer, not an error.
                if Self.error(answer) == .notFound { return [] }
                throw Self.error(answer)
            }
            guard let page = Dropbox.page(fromBody: answer.body) else {
                throw BackupProviderError.rejected(message: "Dropbox sent a page Empo cannot read")
            }
            pages.append(page)
            guard page.hasMore else { break }

            request = try await apiRequest(.listFolderContinue)
            request.httpBody = Data(Self.json(["cursor": page.cursor]).utf8)
        }
        return Dropbox.objects(fromPages: pages, prefix: prefix)
    }

    // MARK: - Upload

    /// The commit argument. `overwrite` is what makes a second run of
    /// the same blob land on the same path, and `autorename` false is
    /// what keeps Dropbox from inventing a second name.
    private static func commit(path: String) -> [String: Any] {
        [
            "path": Dropbox.apiPath(for: path),
            "mode": "overwrite",
            "autorename": false,
            "mute": true,
            "strict_conflict": false,
        ]
    }

    private func uploadWhole(_ localFile: URL, to path: String) async throws(BackupProviderError) {
        let request = try await contentRequest(
            .upload, argument: Self.json(Self.commit(path: path)))
        let answer = try await BackupTransferSession.shared.upload(
            file: localFile, request: request, path: path)
        guard answer.isSuccess else { throw Self.error(answer) }
    }

    /// The session path of 9.2. Nothing appears at the target path
    /// until `finish` commits, which is how this meets 8.2.
    private func uploadSession(
        _ localFile: URL, to path: String, size: Int64, chunks: [Dropbox.Chunk]
    ) async throws(BackupProviderError) {
        let scratch = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        var left = chunks
        var sessionId: String?
        var offset: Int64 = 0

        while let chunk = left.first {
            let piece = try Self.piece(of: localFile, chunk: chunk, in: scratch)
            defer { try? FileManager.default.removeItem(at: piece) }

            let answer: HTTPAnswer
            if let sessionId {
                let argument = Self.json([
                    "cursor": ["session_id": sessionId, "offset": chunk.offset],
                    "close": false,
                ])
                answer = try await BackupTransferSession.shared.upload(
                    file: piece,
                    request: try await contentRequest(.uploadSessionAppend, argument: argument),
                    path: path)
            } else {
                answer = try await BackupTransferSession.shared.upload(
                    file: piece,
                    request: try await contentRequest(
                        .uploadSessionStart, argument: Self.json(["close": false])),
                    path: path)
            }

            if answer.isSuccess {
                if sessionId == nil { sessionId = Self.sessionId(inBody: answer.body) }
                offset = chunk.endOffset
                left.removeFirst()
                continue
            }

            // Dropbox says where the session really stands. Starting
            // again from zero would cost every byte already sent.
            guard let corrected = Dropbox.correctedOffset(inBody: answer.body), sessionId != nil
            else {
                throw Self.error(answer)
            }
            offset = corrected
            left = Dropbox.chunks(ofFileSize: size, from: corrected)
        }

        guard let sessionId else {
            throw BackupProviderError.rejected(message: "Dropbox opened no upload session")
        }
        try await finish(sessionId: sessionId, offset: offset, path: path, scratch: scratch)
    }

    private func finish(
        sessionId: String, offset: Int64, path: String, scratch: URL
    ) async throws(BackupProviderError) {
        let argument = Self.json([
            "cursor": ["session_id": sessionId, "offset": offset],
            "commit": Self.commit(path: path),
        ])
        // `finish` sends no bytes, and a background upload wants a
        // file, so it gets an empty one.
        let empty = scratch.appendingPathComponent("finish")
        guard (try? Data().write(to: empty)) != nil else {
            throw BackupProviderError.rejected(message: "this device could not stage the commit")
        }
        defer { try? FileManager.default.removeItem(at: empty) }

        let answer = try await BackupTransferSession.shared.upload(
            file: empty,
            request: try await contentRequest(.uploadSessionFinish, argument: argument),
            path: path)
        guard answer.isSuccess else { throw Self.error(answer) }
    }

    // MARK: - delete_batch

    /// How long the poll of an async delete waits before it leaves
    /// the rest for the next pass.
    private static let deleteJobWait: TimeInterval = 60
    private static let deleteJobPollWait: TimeInterval = 1

    private func deleteOneBatch(_ paths: [String]) async throws(BackupProviderError) {
        var request = try await apiRequest(.deleteBatch)
        request.httpBody = Data(
            Self.json([
                "entries": paths.map { ["path": Dropbox.apiPath(for: $0)] }
            ]).utf8)

        let answer = try await BackupAPISession.shared.send(request)
        guard answer.isSuccess else { throw Self.error(answer) }

        // A large batch runs as a job. A small one is already done.
        guard let job = Self.asyncJobId(inBody: answer.body) else { return }
        try await waitForDelete(job: job)
    }

    private func waitForDelete(job: String) async throws(BackupProviderError) {
        var left = Self.deleteJobWait
        while left > 0 {
            var request = try await apiRequest(.deleteBatchCheck)
            request.httpBody = Data(Self.json(["async_job_id": job]).utf8)

            let answer = try await BackupAPISession.shared.send(request)
            guard answer.isSuccess else { throw Self.error(answer) }
            if Self.tag(inBody: answer.body) != "in_progress" { return }

            try? await Task.sleep(for: .seconds(Self.deleteJobPollWait))
            left -= Self.deleteJobPollWait
        }
        // The job is still running on Dropbox's side. It finishes
        // there, and the sweep of 5.11 checks again on the next pass.
    }

    // MARK: - The requests

    private func apiRequest(
        _ endpoint: Dropbox.Endpoint
    ) async throws(BackupProviderError) -> URLRequest {
        guard let url = endpoint.url else {
            throw BackupProviderError.rejected(message: "Empo built no URL for \(endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func contentRequest(
        _ endpoint: Dropbox.Endpoint, argument: String
    ) async throws(BackupProviderError) -> URLRequest {
        guard let url = endpoint.url else {
            throw BackupProviderError.rejected(message: "Empo built no URL for \(endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(Dropbox.headerSafe(argument), forHTTPHeaderField: "Dropbox-API-Arg")
        return request
    }

    // MARK: - The bodies

    private static func error(_ answer: HTTPAnswer) -> BackupProviderError {
        Dropbox.error(
            status: answer.status,
            errorSummary: Dropbox.errorSummary(inBody: answer.body),
            retryAfterHeader: answer.retryAfterHeader)
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func sessionId(inBody body: Data) -> String? {
        field("session_id", inBody: body) as? String
    }

    private static func asyncJobId(inBody body: Data) -> String? {
        field("async_job_id", inBody: body) as? String
    }

    private static func tag(inBody body: Data) -> String? {
        field(".tag", inBody: body) as? String
    }

    private static func field(_ name: String, inBody body: Data) -> Any? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return root[name]
    }

    // MARK: - The file work

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("empo-dropbox-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One chunk of the file, as a file of its own.
    ///
    /// A background URLSession uploads from a file and from nothing
    /// else, so an append needs its bytes on disk first.
    private static func piece(
        of localFile: URL, chunk: Dropbox.Chunk, in scratch: URL
    ) throws(BackupProviderError) -> URL {
        let url = scratch.appendingPathComponent("chunk-\(chunk.offset)")
        do {
            let handle = try FileHandle(forReadingFrom: localFile)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(chunk.offset))
            let bytes = try handle.read(upToCount: Int(chunk.length)) ?? Data()
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw BackupProviderError.rejected(
                message: "this device could not stage the upload: \(error.localizedDescription)")
        }
        return url
    }
}

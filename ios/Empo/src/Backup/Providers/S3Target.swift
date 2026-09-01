import Foundation
import GameProbe

/// The S3-compatible target of SPEC 9.4, the first target the user
/// hosts themselves.
///
/// It covers AWS S3, Cloudflare R2, MinIO, and the S3 API of
/// Backblaze B2. No AWS SDK ships, per 9.4: every SDK in this space
/// brings its own HTTP stack and cannot use a background URLSession
/// directly. So Empo signs SigV4 by hand and rides the one background
/// session of 7.3.
///
/// The rules a test can reach live in `S3` and `S3SigV4`, inside
/// GameProbe: the signature, the queries, the upload plan, the
/// paging, and the error map. This file needs a bucket.
///
/// **Two ways to sign, per 9.4.** A call that moves no file signs in
/// its `Authorization` header and goes out at once. A call that moves
/// a file takes a presigned URL, because the background daemon starts
/// the transfer when the system allows, which can be hours later, and
/// a header signature would be too old by then.
actor S3Target: BackupProvider {

    nonisolated let capabilities = S3.capabilities

    private let connection: S3Connection
    private let gate = TransferGate()

    /// Every key this process committed. S3 answers a `PutObject` and
    /// a `CompleteMultipartUpload` only after the object is durable,
    /// so a committed key is durable, per 8.5.
    private var committed: Set<String> = []

    /// How many times running the service has throttled this target.
    /// The truncated backoff of 9.4 reads it, and a call that
    /// succeeds puts it back to one.
    private var throttleAttempt = 1

    /// The largest file that takes one `PutObject`. It is the 5 GiB
    /// of 9.4, and a device check lowers it to drive the multipart
    /// path with a file a phone can write.
    private let singleUploadLimit: Int64
    /// What one part holds before the file size forces a larger one.
    private let partBase: Int64

    init(
        connection: S3Connection,
        singleUploadLimit: Int64 = S3.singleUploadLimitBytes,
        partBase: Int64 = S3.defaultPartBytes
    ) {
        self.connection = connection
        self.singleUploadLimit = singleUploadLimit
        self.partBase = partBase
    }

    private var bucket: S3Bucket { connection.bucket }

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
            switch S3.uploadPlan(
                forFileOfSize: size, singleLimit: self.singleUploadLimit, base: self.partBase)
            {
            case .single:
                try await self.putWhole(localFile, key: path)
            case .multipart(let parts):
                try await self.putInParts(localFile, key: path, size: size, parts: parts)
            }
        }
        committed.insert(path)
    }

    /// Whether the object is durable, per 8.5.
    ///
    /// S3 answers a commit only after the object is durable, so a
    /// `put` that returned is already durable. A new process holds no
    /// record of that, and one `HEAD` tells it.
    func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation {
        if committed.contains(path) { return .confirmed }
        return try await gate.request { () async throws(BackupProviderError) -> PutConfirmation in
            try await self.head(path)
        }
    }

    func get(path: String, localFile: URL) async throws(BackupProviderError) {
        try await gate.transfer { () async throws(BackupProviderError) in
            try await self.getOne(path, to: localFile)
        }
    }

    func delete(paths: [String]) async throws(BackupProviderError) {
        // One `DELETE` per key. The batch call of the API wants a
        // Content-MD5 header that R2 and MinIO each treat their own
        // way, and a prune deletes tens of keys, not thousands.
        for path in paths {
            try await gate.request { () async throws(BackupProviderError) in
                try await self.deleteOne(path)
            }
        }
    }

    private func head(_ path: String) async throws(BackupProviderError) -> PutConfirmation {
        let answer = try await BackupAPISession.shared.send(try signed(method: "HEAD", key: path))
        // A `HEAD` answers no body, so the status is all there is to
        // read.
        try check(answer)
        committed.insert(path)
        return .confirmed
    }

    private func getOne(_ path: String, to localFile: URL) async throws(BackupProviderError) {
        var request = URLRequest(url: try presigned(method: "GET", key: path))
        request.httpMethod = "GET"
        let answer = try await BackupAPISession.shared.download(request, to: localFile)
        try check(answer)
    }

    private func deleteOne(_ path: String) async throws(BackupProviderError) {
        let answer = try await BackupAPISession.shared.send(try signed(method: "DELETE", key: path))
        // A key that holds no object is not an error, per 8.1. The
        // delete has already got what it asked for.
        guard answer.isSuccess || answer.status == S3.Status.notFound else {
            throw mapped(answer)
        }
        throttleAttempt = 1
        committed.remove(path)
    }

    /// This target answers no space query, per 9.7. The limit shows
    /// up as an upload error and follows the ladder of 5.14, and 13.6
    /// states what the target screen shows instead.
    func quota() async throws(BackupProviderError) -> QuotaReading? {
        nil
    }

    // MARK: - ListObjectsV2

    private func everyPage(under prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        var pages: [S3.ObjectPage] = []
        var token: String?
        while true {
            let request = try signed(
                method: "GET",
                query: S3.listQuery(prefix: prefix, continuationToken: token))
            let answer = try await BackupAPISession.shared.send(request)
            try check(answer)
            guard let page = S3.page(fromBody: answer.body) else {
                throw BackupProviderError.rejected(
                    message: "the bucket sent a page Empo cannot read")
            }
            pages.append(page)
            guard page.hasMore, let next = page.nextContinuationToken else { break }
            token = next
        }
        return S3.objects(fromPages: pages)
    }

    // MARK: - PutObject

    /// One `PutObject`, for a file up to 5 GiB, per 9.4. S3 commits a
    /// key whole, which meets 8.2.
    private func putWhole(_ localFile: URL, key: String) async throws(BackupProviderError) {
        var request = URLRequest(url: try presigned(method: "PUT", key: key))
        request.httpMethod = "PUT"
        let answer = try await BackupTransferSession.shared.upload(
            file: localFile, request: request, path: key)
        try check(answer)
    }

    // MARK: - The multipart upload

    /// The multipart path of 9.4. The key holds nothing until
    /// `CompleteMultipartUpload` answers, which is the commit of 8.2.
    private func putInParts(
        _ localFile: URL, key: String, size: Int64, parts: [S3.Part]
    ) async throws(BackupProviderError) {
        let scratch = UploadStaging.scratchDirectory("s3")
        defer { try? FileManager.default.removeItem(at: scratch) }

        var record = try await openUpload(key: key, size: size, parts: parts)
        var left = S3.parts(ofFileSize: size, partSize: record.partSize)
        var startedAgain = false

        while let part = left.first {
            // A part the service already holds is a part this run
            // does not pay for again.
            if record.eTag(ofPart: part.number) != nil {
                left.removeFirst()
                continue
            }

            let piece = try UploadStaging.piece(
                of: localFile, offset: part.offset, length: part.length,
                named: "part-\(part.number)", in: scratch)
            defer { try? FileManager.default.removeItem(at: piece) }

            let answer: HTTPAnswer
            do {
                var request = URLRequest(
                    url: try presigned(
                        method: "PUT", key: key,
                        query: S3.partQuery(number: part.number, uploadId: record.uploadId)))
                request.httpMethod = "PUT"
                answer = try await BackupTransferSession.shared.upload(
                    file: piece, request: request, path: key)
            } catch {
                try await abortIfPermanent(error, uploadId: record.uploadId, key: key)
                throw error
            }

            if answer.isSuccess {
                guard let eTag = answer.header("ETag"), !eTag.isEmpty else {
                    let missing = BackupProviderError.rejected(
                        message: "the bucket took a part and named no ETag")
                    try await abortIfPermanent(missing, uploadId: record.uploadId, key: key)
                    throw missing
                }
                throttleAttempt = 1
                record = record.adding(S3.CompletedPart(number: part.number, eTag: eTag))
                await S3MultipartStore.shared.remember(record)
                left.removeFirst()
                continue
            }

            let failure = S3.failure(inBody: answer.body)
            // The service dropped the upload, and every part with it.
            // One fresh start, so a service that keeps answering this
            // cannot make the run loop.
            if S3.isUploadGone(status: answer.status, failure: failure), !startedAgain {
                startedAgain = true
                await S3MultipartStore.shared.forget(key: key)
                BackupLog.line("S3Target", "the bucket dropped the upload, so it starts again")
                record = try await startUpload(key: key, size: size, parts: parts)
                left = S3.parts(ofFileSize: size, partSize: record.partSize)
                continue
            }

            let error = mapped(answer)
            try await abortIfPermanent(error, uploadId: record.uploadId, key: key)
            throw error
        }

        try await commit(record)
    }

    /// The upload to carry on from, or a new one.
    private func openUpload(
        key: String, size: Int64, parts: [S3.Part]
    ) async throws(BackupProviderError) -> S3MultipartUpload {
        guard let saved = await S3MultipartStore.shared.upload(forKey: key, fileSize: size) else {
            return try await startUpload(key: key, size: size, parts: parts)
        }
        // The record on disk may be one part behind what the service
        // took, and the service is the truth.
        guard let found = try await listParts(uploadId: saved.uploadId, key: key) else {
            await S3MultipartStore.shared.forget(key: key)
            return try await startUpload(key: key, size: size, parts: parts)
        }
        BackupLog.line(
            "S3Target", "the upload carries on with \(found.count) parts of \(parts.count)")
        let record = saved.matching(found)
        await S3MultipartStore.shared.remember(record)
        return record
    }

    /// Opens one multipart upload, after it clears what an earlier
    /// run left on this key.
    private func startUpload(
        key: String, size: Int64, parts: [S3.Part]
    ) async throws(BackupProviderError) -> S3MultipartUpload {
        try await abandonedUploads(ofKey: key)

        let answer = try await BackupAPISession.shared.send(
            try signed(method: "POST", key: key, query: S3.uploadsQuery()))
        try check(answer)
        guard let uploadId = S3.uploadId(fromBody: answer.body) else {
            throw BackupProviderError.rejected(message: "the bucket opened no multipart upload")
        }

        let record = S3MultipartUpload(
            uploadId: uploadId,
            key: key,
            fileSize: size,
            partSize: parts.first?.length ?? S3.partSize(forFileOfSize: size, base: partBase),
            startedAt: Date())
        await S3MultipartStore.shared.remember(record)
        return record
    }

    /// Aborts every multipart upload the service still holds for this
    /// key.
    ///
    /// An abandoned upload leaves parts, and parts cost money, per
    /// 9.4. A run that died between two parts left an upload nothing
    /// will ever finish, and this is where it goes.
    private func abandonedUploads(ofKey key: String) async throws(BackupProviderError) {
        let answer = try await BackupAPISession.shared.send(
            try signed(method: "GET", query: S3.uploadsQuery(prefix: key)))
        // A service that does not answer this list is not a reason to
        // refuse the upload. The next `CreateMultipartUpload` still
        // works, and the parts of the older one stay until a rule of
        // the bucket clears them.
        guard answer.isSuccess else { return }
        for uploadId in S3.uploadIds(fromBody: answer.body, key: key) {
            BackupLog.line("S3Target", "an earlier run left parts, so this one aborts them")
            await abort(uploadId: uploadId, key: key)
        }
    }

    /// The parts the service holds, or `nil` when it no longer holds
    /// the upload at all.
    private func listParts(
        uploadId: String, key: String
    ) async throws(BackupProviderError) -> [S3.CompletedPart]? {
        let answer = try await BackupAPISession.shared.send(
            try signed(method: "GET", key: key, query: S3.uploadQuery(uploadId: uploadId)))
        if answer.isSuccess {
            throttleAttempt = 1
            return S3.completedParts(fromBody: answer.body)
        }
        let failure = S3.failure(inBody: answer.body)
        guard S3.isUploadGone(status: answer.status, failure: failure) else {
            throw mapped(answer)
        }
        return nil
    }

    /// `CompleteMultipartUpload`, which is the commit of 8.2.
    private func commit(_ record: S3MultipartUpload) async throws(BackupProviderError) {
        let body = S3.completeBody(parts: record.parts)
        var request = try signed(
            method: "POST", key: record.key,
            query: S3.uploadQuery(uploadId: record.uploadId), body: body)
        request.httpBody = body

        let answer = try await BackupAPISession.shared.send(request)
        // The service answers 200 and then writes the failure into
        // the body, because it holds the connection open while it
        // joins the parts. A body that names an error is a failure.
        let failure = S3.failure(inBody: answer.body)
        guard answer.isSuccess, failure.code.isEmpty else {
            let error =
                answer.isSuccess
                ? S3.error(status: S3.Status.badRequest, failure: failure) : mapped(answer)
            try await abortIfPermanent(error, uploadId: record.uploadId, key: record.key)
            throw error
        }
        throttleAttempt = 1
        await S3MultipartStore.shared.forget(key: record.key)
    }

    /// Aborts the upload where the failure is permanent, per 9.4.
    private func abortIfPermanent(
        _ error: BackupProviderError, uploadId: String, key: String
    ) async throws(BackupProviderError) {
        guard S3.abortsMultipart(after: error) else { return }
        await abort(uploadId: uploadId, key: key)
        await S3MultipartStore.shared.forget(key: key)
    }

    /// One `AbortMultipartUpload`. It reports nothing, because the
    /// caller is already on its way out with the failure that brought
    /// it here.
    private func abort(uploadId: String, key: String) async {
        guard
            let request = try? signed(
                method: "DELETE", key: key, query: S3.uploadQuery(uploadId: uploadId))
        else { return }
        _ = try? await BackupAPISession.shared.send(request)
    }

    // MARK: - The two ways to sign

    /// One request signed in its `Authorization` header, per 9.4.
    private func signed(
        method: String,
        key: String = "",
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) throws(BackupProviderError) -> URLRequest {
        if let refusal = bucket.refusal { throw refusal }
        guard let url = bucket.url(key: key, query: query), let host = bucket.host else {
            throw BackupProviderError.rejected(message: "Empo built no address for the bucket")
        }

        let payloadHash = body.map { ContentHash.hex(of: $0) } ?? S3SigV4.emptyPayloadHash
        var headers = ["host": host]
        if body != nil { headers["Content-Type"] = "application/xml" }

        let signature = S3SigV4.signInHeader(
            method: method,
            canonicalPath: bucket.canonicalPath(key: key),
            query: query,
            headers: headers,
            payloadHash: payloadHash,
            credentials: connection.credentials,
            region: bucket.region,
            date: Date())

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in signature.headers where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// One presigned URL, per 9.4. Every call that moves a file takes
    /// one, so the background daemon can send it without a header of
    /// its own, days later if the system waits that long.
    private func presigned(
        method: String, key: String, query: [URLQueryItem] = []
    ) throws(BackupProviderError) -> URL {
        if let refusal = bucket.refusal { throw refusal }
        guard let scheme = bucket.scheme, let host = bucket.host else {
            throw BackupProviderError.rejected(message: "Empo built no address for the bucket")
        }
        guard
            let presigned = S3SigV4.presign(
                method: method,
                scheme: scheme,
                host: host,
                port: bucket.port,
                canonicalPath: bucket.canonicalPath(key: key),
                query: query,
                credentials: connection.credentials,
                region: bucket.region,
                date: Date())
        else {
            throw BackupProviderError.rejected(message: "Empo built no address for the bucket")
        }
        return presigned.url
    }

    // MARK: - The answers

    private func check(_ answer: HTTPAnswer) throws(BackupProviderError) {
        guard answer.isSuccess else { throw mapped(answer) }
        throttleAttempt = 1
    }

    /// One S3 answer onto one error kind of 8.4, with the truncated
    /// backoff of 9.4 on a throttle.
    private func mapped(_ answer: HTTPAnswer) -> BackupProviderError {
        let error = S3.error(
            status: answer.status,
            failure: S3.failure(inBody: answer.body),
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

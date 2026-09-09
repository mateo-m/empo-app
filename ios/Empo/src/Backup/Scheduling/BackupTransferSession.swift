import Foundation
import GameProbe

/// The one background URLSession of SPEC 7.3 and 9.2.
///
/// One file-based background session for the whole app, with one
/// identifier and one delegate. Every HTTP provider shares it. A
/// second session stack beside Empo's own is the reason Dropbox is
/// hand-rolled rather than taken from SwiftyDropbox, per 9.2.
///
/// The session uploads from a file only. That is the one transfer
/// that survives suspension, and section 7 rests on it.
///
/// The two network flags of 7.4 sit on both the configuration and
/// each request. A background session fixes its configuration at
/// creation, so a user who turns the cellular switch on mid-life
/// would keep the old value without the per-request copy.
final class BackupTransferSession: NSObject {

    static let shared = BackupTransferSession()

    /// One identifier for the whole app. A second one would make a
    /// second daemon queue, and the launch rate limiter counts them
    /// together.
    static let identifier = "sh.mateo.empo.backup.transfers"

    /// What the daemon holds for one transfer, so a delegate
    /// callback finds its caller again.
    ///
    /// The body accumulates, because a provider reads its own reason
    /// out of it. Dropbox writes `error_summary` there, and a 409
    /// says nothing without it, per 9.2.
    private final class PendingTransfer {
        let path: String
        let resume: (Result<HTTPAnswer, BackupProviderError>) -> Void
        var body = Data()
        var bodyStarts = 0
        var gaveUp = false
        /// Where a download lands. A successful download moves its
        /// file here before it completes, and the body stays empty.
        var localFile: URL?

        init(path: String, resume: @escaping (Result<HTTPAnswer, BackupProviderError>) -> Void) {
            self.path = path
            self.resume = resume
        }
    }

    private var pending: [Int: PendingTransfer] = [:]

    /// iOS 27: a background session retries a timed-out upload on its
    /// own every 60 to 75 s until `timeoutIntervalForResource` (7 days)
    /// and tells the app nothing. Each retry sends the body from zero,
    /// so the count of body starts is the only signal.
    static let bodyStartsBeforeGivingUp = 3
    /// The bytes sent that the monitor last heard about, per task.
    private var reportedBytes: [Int: Int64] = [:]
    private let lock = NSLock()

    /// The completion handler iOS hands the app when it wakes it for
    /// this session, per `handleEventsForBackgroundURLSession`.
    private var systemWakeCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        // The system decides when a suspended app's transfers run.
        // Empo does not ask for discretionary scheduling on top,
        // because the backbone trigger of 7.3 is the moment the user
        // just stopped playing.
        configuration.isDiscretionary = false
        configuration.allowsExpensiveNetworkAccess =
            BackupNetwork.policy.allowsExpensiveNetworkAccess
        configuration.allowsConstrainedNetworkAccess =
            BackupNetwork.policy.allowsConstrainedNetworkAccess
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    /// Builds the session before the first transfer, so a launch
    /// that only recovers still reconnects to the daemon.
    func start() {
        _ = session
    }

    /// The two flags of 7.4 on one request. Every provider sends its
    /// upload through here.
    func request(_ base: URLRequest) -> URLRequest {
        var request = base
        let policy = BackupNetwork.policy
        request.allowsExpensiveNetworkAccess = policy.allowsExpensiveNetworkAccess
        request.allowsConstrainedNetworkAccess = policy.allowsConstrainedNetworkAccess
        return request
    }

    /// Uploads one file. The task outlives the app, so the caller's
    /// continuation resumes from the delegate.
    ///
    /// It throws on a transport failure alone. An HTTP status the
    /// service answered comes back whole, because only the provider
    /// knows what its own body means, per 8.4.
    func upload(
        file: URL, request: URLRequest, path: String
    ) async throws(BackupProviderError) -> HTTPAnswer {
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<HTTPAnswer, BackupProviderError>, Never>) in
            let task = session.uploadTask(with: self.request(request), fromFile: file)
            task.taskDescription = path
            lock.lock()
            pending[task.taskIdentifier] = PendingTransfer(path: path) { answer in
                continuation.resume(returning: answer)
            }
            lock.unlock()
            task.resume()
        }
        return try result.get()
    }

    /// Downloads one object to a file, per 11.9. The task outlives
    /// the app the way an upload does, so a restore keeps going
    /// while the user is elsewhere.
    ///
    /// On a 2xx the file is at `localFile` when this returns and the
    /// answer's body is empty. On any other status the body carries
    /// what the service said and no file is written.
    func download(
        _ request: URLRequest, to localFile: URL, path: String
    ) async throws(BackupProviderError) -> HTTPAnswer {
        // A game launch cancels the restore's task, and 7.6 wants the
        // download to stop with it. Uploads keep going on a cancel,
        // per 7.5, so only this path listens.
        guard !Task.isCancelled else { throw .offline }
        let task = session.downloadTask(with: self.request(request))
        // The description names the file the download lands in,
        // so a process that died mid-download still gets the
        // file: the daemon finishes it, wakes the app, and the
        // delegate below reads the destination from here.
        task.taskDescription = Self.downloadMark + localFile.path
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<HTTPAnswer, BackupProviderError>, Never>) in
                let transfer = PendingTransfer(path: path) { answer in
                    continuation.resume(returning: answer)
                }
                transfer.localFile = localFile
                lock.lock()
                pending[task.taskIdentifier] = transfer
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return try result.get()
    }

    /// The tasks the daemon still holds for this app.
    ///
    /// The launch recovery of 7.10 reads it. A run that never
    /// finished and has no task left here died with the process.
    /// iOS 27 keeps a task that finished while the app was dead in
    /// `allTasks` as `.completed` until the delegate hears about it,
    /// so only a running or suspended task counts as live. A
    /// download is a restore's, and the resume question of 11.9
    /// owns that one, so it does not count here.
    func liveTaskPaths() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(
            tasks
                .filter { $0.state == .running || $0.state == .suspended }
                .compactMap(\.taskDescription)
                .filter { !$0.hasPrefix(Self.downloadMark) })
    }

    private static let downloadMark = "get "

    /// Cancels every transfer in flight. A user pause is the one
    /// thing that may call this, per 7.5.
    func cancelEveryTransfer() async {
        for task in await session.allTasks {
            task.cancel()
        }
    }

    /// iOS woke the app to finish this session's events. The handler
    /// runs once the delegate reports it is done.
    func takeSystemWake(completion: @escaping () -> Void) {
        systemWakeCompletion = completion
        start()
    }

    private func finish(
        taskIdentifier: Int, with result: Result<HTTPAnswer, BackupProviderError>
    ) {
        lock.lock()
        let transfer = pending.removeValue(forKey: taskIdentifier)
        reportedBytes.removeValue(forKey: taskIdentifier)
        lock.unlock()
        transfer?.resume(result)
    }

    private func giveUpOnTheFourthStart(of task: URLSessionTask) {
        lock.lock()
        let transfer = pending[task.taskIdentifier]
        transfer?.bodyStarts += 1
        let starts = transfer?.bodyStarts ?? 0
        let giveUp = starts > Self.bodyStartsBeforeGivingUp && transfer?.gaveUp == false
        if giveUp { transfer?.gaveUp = true }
        lock.unlock()
        guard giveUp else { return }
        BackupLog.line(
            "BackupTransferSession",
            "\(task.taskDescription ?? "?") got no answer in \(starts - 1) tries, gives up")
        task.cancel()
    }

    private func collect(_ data: Data, taskIdentifier: Int) {
        lock.lock()
        pending[taskIdentifier]?.body.append(data)
        lock.unlock()
    }

    private func body(ofTask taskIdentifier: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return pending[taskIdentifier]?.body ?? Data()
    }
}

/// What a service answered, before any provider reads it.
struct HTTPAnswer: Sendable {
    let status: Int
    let body: Data
    /// Every response header. A provider reads the ones it needs:
    /// `Retry-After` for the throttle of 8.6, and, on Google Drive,
    /// `Location` for a new upload session and `Range` for the offset
    /// a broken one reached, per 9.3.
    let headers: [String: String]

    init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    init(status: Int, body: Data, response: HTTPURLResponse) {
        self.init(status: status, body: body, headers: Self.headers(of: response))
    }

    var isSuccess: Bool { (200..<300).contains(status) }

    /// One header by name. HTTP header names are case-insensitive,
    /// and a service may send `location` or `Location`.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var retryAfterHeader: String? { header("Retry-After") }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var found: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            found[name] = String(describing: value)
        }
        return found
    }
}

extension BackupTransferSession: URLSessionDataDelegate, URLSessionDownloadDelegate {

    /// The temporary file is gone once this returns, so the move
    /// happens here and not where the continuation resumes.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let transfer = pending[downloadTask.taskIdentifier]
        lock.unlock()
        let http = downloadTask.response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            // The body carries the reason, not the file. Nobody reads
            // it when the caller died with the process.
            guard transfer != nil else { return }
            collect(
                (try? Data(contentsOf: location)) ?? Data(),
                taskIdentifier: downloadTask.taskIdentifier)
            return
        }
        let described = (downloadTask.taskDescription ?? "").dropFirst(Self.downloadMark.count)
        let localFile = transfer?.localFile ?? URL(fileURLWithPath: String(described))
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: localFile.path) {
                try manager.removeItem(at: localFile)
            }
            try manager.moveItem(at: location, to: localFile)
        } catch {
            BackupLog.line(
                "BackupTransferSession",
                "\(downloadTask.taskDescription ?? "?") landed but could not move: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        collect(data, taskIdentifier: dataTask.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        if totalBytesSent == bytesSent {
            BackupLog.line(
                "BackupTransferSession",
                "\(task.taskDescription ?? "?") sends \(totalBytesExpectedToSend) bytes")
            giveUpOnTheFourthStart(of: task)
        }
        // The session calls this for every chunk of the body. One
        // hop to the main actor per megabyte is enough for a pill.
        lock.lock()
        let last = reportedBytes[task.taskIdentifier] ?? 0
        let moved = totalBytesSent - last >= 1_000_000 || totalBytesSent == totalBytesExpectedToSend
        if moved { reportedBytes[task.taskIdentifier] = totalBytesSent }
        lock.unlock()
        guard moved else { return }
        Task { await BackupRunMonitor.shared.transferSent(bytes: totalBytesSent) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        let http = task.response as? HTTPURLResponse
        if let error {
            BackupLog.line(
                "BackupTransferSession",
                "\(task.taskDescription ?? "?") ended with \(error.localizedDescription)")
        } else if let http, !(200..<300).contains(http.statusCode) {
            BackupLog.line(
                "BackupTransferSession", "\(task.taskDescription ?? "?") answered \(http.statusCode)")
        }
        if let error {
            // A transport error after the headers arrived still means
            // no body and no file. A download cut mid-way carries its
            // 200 in `task.response`, and reading that as a success
            // would send an empty file to the hash check.
            lock.lock()
            let gaveUp = pending[task.taskIdentifier]?.gaveUp ?? false
            lock.unlock()
            finish(
                taskIdentifier: task.taskIdentifier,
                with: .failure(gaveUp ? .offline : Self.providerError(error)))
            return
        }
        guard let http else {
            finish(taskIdentifier: task.taskIdentifier, with: .failure(.offline))
            return
        }
        finish(
            taskIdentifier: task.taskIdentifier,
            with: .success(
                HTTPAnswer(
                    status: http.statusCode,
                    body: body(ofTask: task.taskIdentifier),
                    response: http)))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = systemWakeCompletion
        systemWakeCompletion = nil
        DispatchQueue.main.async { completion?() }
    }

    /// The transport error kinds of 8.4, for a request that got no
    /// answer at all. A request that did get one goes back whole, and
    /// the provider reads its own body.
    private static func providerError(_ error: Error) -> BackupProviderError {
        let error = error as NSError
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return .offline
        default:
            // A certificate the system does not trust says so once,
            // with the line of 8.11. A user who typed their own
            // address is the one who needs to read it.
            return TransportSecurity.certificateError(
                urlErrorCode: error.code, description: error.localizedDescription)
                ?? .rejected(message: error.localizedDescription)
        }
    }

}

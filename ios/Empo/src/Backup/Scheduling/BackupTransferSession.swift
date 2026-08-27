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
    private struct PendingTransfer {
        let path: String
        let resume: (Result<Void, BackupProviderError>) -> Void
    }

    private var pending: [Int: PendingTransfer] = [:]
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
    func upload(file: URL, request: URLRequest, path: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let task = session.uploadTask(with: self.request(request), fromFile: file)
            task.taskDescription = path
            lock.lock()
            pending[task.taskIdentifier] = PendingTransfer(path: path) { result in
                continuation.resume(with: result)
            }
            lock.unlock()
            task.resume()
        }
    }

    /// The tasks the daemon still holds for this app.
    ///
    /// The launch recovery of 7.10 reads it. A run that never
    /// finished and has no task left here died with the process.
    func liveTaskPaths() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap(\.taskDescription))
    }

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

    private func finish(taskIdentifier: Int, with result: Result<Void, BackupProviderError>) {
        lock.lock()
        let transfer = pending.removeValue(forKey: taskIdentifier)
        lock.unlock()
        transfer?.resume(result)
    }
}

extension BackupTransferSession: URLSessionDataDelegate {

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        if let error {
            finish(
                taskIdentifier: task.taskIdentifier,
                with: .failure(Self.providerError(error, response: task.response)))
            return
        }
        if let failure = Self.providerError(status: task.response) {
            finish(taskIdentifier: task.taskIdentifier, with: .failure(failure))
            return
        }
        finish(taskIdentifier: task.taskIdentifier, with: .success(()))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = systemWakeCompletion
        systemWakeCompletion = nil
        DispatchQueue.main.async { completion?() }
    }

    /// The transport error kinds of 8.4. A provider maps its own
    /// body on top. This covers what URLSession answers on its own.
    private static func providerError(
        _ error: Error, response: URLResponse?
    ) -> BackupProviderError {
        if let failure = providerError(status: response) { return failure }
        switch (error as NSError).code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return .offline
        default:
            return .rejected(message: error.localizedDescription)
        }
    }

    private static func providerError(status response: URLResponse?) -> BackupProviderError? {
        guard let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 200..<300:
            return nil
        case 401, 403:
            return .authExpired
        case 404:
            return .notFound
        case 429, 503:
            let retryAfter =
                http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 5
            return .throttled(retryAfter: retryAfter)
        case 507:
            return .outOfSpace
        default:
            return .rejected(message: "the target answered \(http.statusCode)")
        }
    }
}

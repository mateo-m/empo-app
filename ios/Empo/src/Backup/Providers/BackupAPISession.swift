import Foundation
import GameProbe

/// The session that carries a request which moves no file.
///
/// `list`, `delete`, `quota`, a token refresh, and the two ends of an
/// upload session are small JSON calls. They finish inside the app's
/// own lifetime and they never have to survive suspension, so they
/// take an ordinary session.
///
/// The one background session of 7.3 stays for the bytes. A second
/// background stack is what 9.2 refuses, and this is not one: it
/// carries no file and it wakes the app for nothing.
///
/// The two network flags of 7.4 ride every request, because the user
/// can turn the cellular switch at any moment.
final class BackupAPISession: Sendable {

    static let shared = BackupAPISession()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        // Measured on macOS 27 and iOS 27: with `waitsForConnectivity`
        // on, a server that accepts the connection and never answers
        // holds the task past 200 s. Neither this timeout nor a
        // request-level one fires. Off, the task fails with -1001 at
        // 61 s, which 8.4 maps to `offline` and the next pass retries.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    /// Sends one request and reads the whole answer.
    func answer(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        let policy = BackupNetwork.policy
        request.allowsExpensiveNetworkAccess = policy.allowsExpensiveNetworkAccess
        request.allowsConstrainedNetworkAccess = policy.allowsConstrainedNetworkAccess
        return try await session.data(for: request)
    }

    /// The same call, as the answer a provider maps, per 8.4.
    ///
    /// A request that got no answer is a transport failure and 8.4
    /// decides from it. A request that did get one comes back whole,
    /// because only the provider knows what its own body means.
    func send(_ request: URLRequest) async throws(BackupProviderError) -> HTTPAnswer {
        do {
            let (data, response) = try await answer(for: request)
            guard let http = response as? HTTPURLResponse else { throw BackupProviderError.offline }
            return HTTPAnswer(status: http.statusCode, body: data, response: http)
        } catch let error as BackupProviderError {
            throw error
        } catch {
            throw Self.transportError(error)
        }
    }

    private static func transportError(_ error: Error) -> BackupProviderError {
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

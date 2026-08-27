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
        configuration.waitsForConnectivity = true
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

    /// Downloads one object to a file.
    ///
    /// The restore of section 11 runs in the foreground with the user
    /// watching, so a download needs no background task.
    func download(
        _ request: URLRequest, to localFile: URL
    ) async throws(BackupProviderError) -> HTTPAnswer {
        do {
            var request = request
            let policy = BackupNetwork.policy
            request.allowsExpensiveNetworkAccess = policy.allowsExpensiveNetworkAccess
            request.allowsConstrainedNetworkAccess = policy.allowsConstrainedNetworkAccess

            let (temporary, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse else { throw BackupProviderError.offline }
            guard (200..<300).contains(http.statusCode) else {
                // The body carries the reason, not the file.
                let body = (try? Data(contentsOf: temporary)) ?? Data()
                try? FileManager.default.removeItem(at: temporary)
                return HTTPAnswer(status: http.statusCode, body: body, response: http)
            }

            let manager = FileManager.default
            try manager.createDirectory(
                at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: localFile.path) {
                try manager.removeItem(at: localFile)
            }
            try manager.moveItem(at: temporary, to: localFile)
            return HTTPAnswer(status: http.statusCode, body: Data(), response: http)
        } catch let error as BackupProviderError {
            throw error
        } catch {
            throw Self.transportError(error)
        }
    }

    private static func transportError(_ error: Error) -> BackupProviderError {
        switch (error as NSError).code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return .offline
        default:
            return .rejected(message: error.localizedDescription)
        }
    }
}

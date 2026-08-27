import Foundation
import GameProbe

/// The access token one OAuth target uses right now, per SPEC 8.10.
///
/// Every call the provider makes goes through `accessToken()`. The
/// store refreshes a token that is about to die, writes the new pair
/// to the Keychain, and hands the same token to every caller that
/// waits, so four transfers in flight make one refresh and not four.
///
/// A refresh the service refuses is the auth loss of 8.10. The store
/// throws `authExpired`, and the effect of 8.4 moves the target to
/// needs-sign-in and stops the run.
actor OAuthTokenStore {

    /// What one service needs to refresh a token.
    struct Service: Sendable {
        let tokenEndpoint: URL
        let clientId: String
    }

    private let targetId: String
    private let service: Service
    private var tokens: OAuthTokens
    /// The refresh in flight, so callers share one.
    private var refresh: Task<OAuthTokens, Error>?

    init(targetId: String, service: Service, tokens: OAuthTokens) {
        self.targetId = targetId
        self.service = service
        self.tokens = tokens
    }

    /// The tokens one target holds, or `nil` where it has none. A
    /// target with none is a placeholder, per 8.8.
    static func tokens(targetId: String) -> OAuthTokens? {
        OAuthTokens.read(targetId: targetId)
    }

    /// A token that is alive now.
    func accessToken() async throws(BackupProviderError) -> String {
        guard tokens.isExpired(at: Date()) else { return tokens.accessToken }

        let task = refresh ?? startRefresh()
        refresh = task
        do {
            let fresh = try await task.value
            tokens = fresh
            refresh = nil
            return fresh.accessToken
        } catch let error as BackupProviderError {
            refresh = nil
            throw error
        } catch {
            refresh = nil
            throw BackupProviderError.offline
        }
    }

    /// Replaces the pair after a sign-in, and drops a refresh that is
    /// no longer about the right account.
    func replace(with tokens: OAuthTokens) throws {
        refresh?.cancel()
        refresh = nil
        self.tokens = tokens
        try tokens.write(targetId: targetId)
    }

    private func startRefresh() -> Task<OAuthTokens, Error> {
        let service = service
        let targetId = targetId
        let current = tokens
        return Task {
            guard let refreshToken = current.refreshToken else {
                throw BackupProviderError.authExpired
            }
            let fresh = try await Self.exchange(refreshToken: refreshToken, service: service)
            var pair = fresh
            // Dropbox answers a refresh without repeating the refresh
            // token. Losing it here would cost the next sign-in.
            pair.refreshToken = fresh.refreshToken ?? refreshToken
            try? pair.write(targetId: targetId)
            return pair
        }
    }

    // MARK: - The refresh call

    private static func exchange(
        refreshToken: String, service: Service
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: service.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            form([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": service.clientId,
            ]).utf8)

        let (data, response) = try await BackupAPISession.shared.answer(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackupProviderError.offline }
        guard http.statusCode == 200 else {
            // The service refused the refresh. Only a new sign-in
            // fixes that, per 8.10.
            throw BackupProviderError.authExpired
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = root["access_token"] as? String
        else {
            throw BackupProviderError.authExpired
        }
        let lifetime = (root["expires_in"] as? NSNumber)?.doubleValue
        return OAuthTokens(
            accessToken: access,
            refreshToken: root["refresh_token"] as? String,
            expiresAt: lifetime.map { Date().addingTimeInterval($0) })
    }

    /// Percent-encodes one form body. A token can carry a character
    /// that a raw join would break.
    private static func form(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return
            fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let text = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(name)=\(text)"
            }
            .joined(separator: "&")
    }
}

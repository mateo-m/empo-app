import Foundation
import GameProbe

/// The access token one OAuth target uses right now, per SPEC 8.10.
///
/// Every call the provider makes goes through `accessToken()`. The
/// store refreshes a token that is about to die, writes the new pair
/// to the Keychain, and hands the same token to every caller that
/// waits, so four transfers in flight make one refresh and not four.
///
/// A refresh token the service calls dead makes the store throw
/// `authExpired`, which moves the target to needs-sign-in and stops
/// the run. An outage or a throttle does not.
actor OAuthTokenStore {

    /// What one service needs to refresh a token.
    struct Service: Sendable {
        let kind: BackupProviderKind
        let tokenEndpoint: URL
        let clientId: String
    }

    let targetId: String
    private let service: Service
    private var tokens: OAuthTokens
    /// The refresh in flight, so callers share one.
    private var refresh: Task<OAuthTokens, Error>?
    /// Counts the sign-ins. A refresh that started before one belongs
    /// to the old pair.
    private var signIns = 0
    /// The provider can refuse the old refresh token after a refresh,
    /// so a pair that only memory holds costs a new sign-in at the
    /// next launch.
    private var tokensAreUnsaved = false

    init(targetId: String, service: Service, tokens: OAuthTokens) {
        self.targetId = targetId
        self.service = service
        self.tokens = tokens
    }

    /// A token that is alive now.
    func accessToken() async throws(BackupProviderError) -> String {
        if tokensAreUnsaved { saveTheTokens() }
        guard tokens.isExpired(at: Date()) else { return tokens.accessToken }
        return try await refreshed()
    }

    private func refreshed() async throws(BackupProviderError) -> String {
        let task = refresh ?? startRefresh()
        refresh = task
        let signInsBefore = signIns
        let result = await task.result
        guard signIns == signInsBefore else { return try await accessToken() }
        // Every caller that shares the refresh comes here. The first
        // one keeps the pair.
        if refresh == task {
            refresh = nil
            if case .success(let fresh) = result {
                tokens = fresh
                saveTheTokens()
            }
        }
        switch result {
        case .success(let fresh):
            return fresh.accessToken
        case .failure(let error):
            throw error as? BackupProviderError ?? .offline
        }
    }

    /// Sends one request with a live token.
    ///
    /// A background transfer waits for a network, and the token can
    /// die while it waits. So a 401 refreshes the token once and sends
    /// the request again. Only a second 401 reaches the caller.
    func send(
        _ request: URLRequest,
        isolation: isolated (any Actor)? = #isolation,
        through transport: (URLRequest) async throws(BackupProviderError) -> HTTPAnswer
    ) async throws(BackupProviderError) -> HTTPAnswer {
        var request = request
        let token = try await accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let answer = try await transport(request)
        guard answer.status == 401 else { return answer }

        let fresh = try await accessToken(replacing: token)
        request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
        return try await transport(request)
    }

    /// A token other than `rejected`. When another call already
    /// replaced it, that one comes back with no second refresh.
    private func accessToken(replacing rejected: String) async throws(BackupProviderError) -> String {
        guard tokens.accessToken == rejected else { return try await accessToken() }
        return try await refreshed()
    }

    /// Replaces the pair after a sign-in, and drops a refresh that is
    /// no longer about the right account.
    func replace(with tokens: OAuthTokens) throws {
        refresh?.cancel()
        refresh = nil
        signIns += 1
        self.tokens = tokens
        try BackupKeychain.setSecret(json: tokens, targetId: targetId)
        tokensAreUnsaved = false
    }

    private func saveTheTokens() {
        do {
            try BackupKeychain.setSecret(json: tokens, targetId: targetId)
            tokensAreUnsaved = false
        } catch {
            tokensAreUnsaved = true
            BackupLog.line("OAuthTokenStore", "The tokens of \(targetId) were not saved: \(error)")
        }
    }

    private func startRefresh() -> Task<OAuthTokens, Error> {
        let service = service
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
            return pair
        }
    }

    // MARK: - The refresh call

    private static func exchange(
        refreshToken: String, service: Service
    ) async throws(BackupProviderError) -> OAuthTokens {
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

        let answer = try await BackupAPISession.shared.send(request)
        guard answer.status == 200 else {
            throw OAuthRefresh.error(
                kind: service.kind, status: answer.status, body: answer.body,
                retryAfterHeader: answer.retryAfterHeader)
        }
        // A captive portal answers 200 with its own page and no token.
        guard let root = try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any],
            let access = root["access_token"] as? String
        else {
            throw BackupProviderError.offline
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

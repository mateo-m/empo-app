import AppAuth
import Foundation
import GameProbe
import UIKit

/// What one service needs for a sign-in, per SPEC 8.10.
struct OAuthService: Sendable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    /// The public client id. A PKCE client holds no secret.
    let clientId: String
    /// The custom URL scheme the callback comes back on. It is never
    /// an https link, because an https callback needs the Associated
    /// Domains entitlement and a sideloaded build does not hold it.
    let redirectURL: URL
    let scopes: [String]
    /// The parameters the service needs beyond the standard set, such
    /// as the one that asks for a refresh token.
    let additionalParameters: [String: String]
}

/// A service that can name the account it signed in to.
protocol AccountReading: Sendable {
    func account() async -> BackupAccount?
}

/// The one OAuth sign-in of SPEC 8.10, for every service that uses
/// one.
///
/// AppAuth carries PKCE and the code exchange. Empo hand-rolls the
/// REST of each provider and nothing else, because an SDK would bring
/// a second background session beside Empo's own, per 9.2 and 9.3.
@MainActor
final class OAuthSignIn {

    struct NoToken: Error {}

    static let shared = OAuthSignIn()

    /// The sign-in in flight. AppAuth needs it to take the callback.
    private var session: OIDExternalUserAgentSession?

    private init() {}

    /// Hands the callback to the sign-in that asked for it.
    ///
    /// The scene delegate calls this. It answers whether the URL
    /// belonged to a sign-in, so an unrelated URL falls through.
    @discardableResult
    func resume(with url: URL) -> Bool {
        guard let session else { return false }
        // AppAuth 3 throws when the URL is not this sign-in's redirect.
        let took = (try? session.resumeExternalUserAgentFlow(url)) != nil
        if took { self.session = nil }
        return took
    }

    /// How long a sign-in waits for the app to reach the foreground.
    /// The app can stay in the background, and then no event comes.
    private static let activeWait: Duration = .seconds(10)

    private var activationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var activationObservers: [NSObjectProtocol] = []

    /// Answers the screen a sheet can come up from.
    ///
    /// AppAuth presents an `ASWebAuthenticationSession`, and that
    /// closes at once when the app is not active yet. A caller that
    /// runs at scene connect is therefore too early, so this waits.
    ///
    /// It answers `nil` when the app never became active.
    static func screenForTheSheet() async -> UIViewController? {
        let deadline = ContinuousClock.now + activeWait
        while true {
            if UIApplication.shared.applicationState == .active,
                let front = frontViewController(), front.viewIfLoaded?.window != nil
            {
                return front
            }
            let left = deadline - ContinuousClock.now
            guard left > .zero else { return nil }
            await shared.nextActivation(within: left)
        }
    }

    /// Waits until the app becomes active or a window becomes key, or
    /// for `limit`.
    private func nextActivation(within limit: Duration) async {
        if activationObservers.isEmpty {
            activationObservers = [
                UIApplication.didBecomeActiveNotification, UIWindow.didBecomeKeyNotification,
            ].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.wakeActivationWaiters() }
                }
            }
        }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            activationWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                self?.activationWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func wakeActivationWaiters() {
        let waiting = activationWaiters.values
        activationWaiters = [:]
        for continuation in waiting { continuation.resume() }
    }

    private static func frontViewController() -> UIViewController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                var top = window.rootViewController
                while let next = top?.presentedViewController { top = next }
                if let top { return top }
            }
        }
        return nil
    }

    /// Whether the user closed the browser instead of signing in.
    private static func isCancel(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == OIDGeneralErrorDomain else { return false }
        return error.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue
            || error.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue
    }

    private static func isOffline(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == OIDGeneralErrorDomain
            && error.code == OIDErrorCode.networkError.rawValue
    }

    /// Signs in to one service and answers the tokens, or `nil` where
    /// the user stopped.
    func signIn(
        service: OAuthService, presenting viewController: UIViewController
    ) async throws -> OAuthTokens? {
        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: service.authorizationEndpoint,
            tokenEndpoint: service.tokenEndpoint)
        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: service.clientId,
            clientSecret: nil,
            scopes: service.scopes,
            redirectURL: service.redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: service.additionalParameters)

        // AppAuth routes a callback URL to one session only. Its cancel
        // dismisses the earlier browser, then ends that sign-in with
        // `userCanceledAuthorizationFlow`, so the earlier caller gets nil.
        if let earlier = session {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                earlier.cancel { continuation.resume() }
            }
        }
        var mine: OIDExternalUserAgentSession?
        let state = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<OIDAuthState?, Error>) in
            mine = OIDAuthState.authState(
                byPresenting: request, presenting: viewController
            ) { state, error in
                if let error, state == nil {
                    // A user who closes the browser stopped the
                    // sign-in. Nothing failed, so the target stays as
                    // it was and the add flow of 13.7 shows no error.
                    if Self.isCancel(error) {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(throwing: Self.isOffline(error) ? BackupProviderError.offline : error)
                    return
                }
                continuation.resume(returning: state)
            }
            session = mine
        }
        if session === mine { session = nil }

        guard let state else { return nil }
        guard let response = state.lastTokenResponse, let access = response.accessToken else {
            throw NoToken()
        }
        return OAuthTokens(
            accessToken: access,
            refreshToken: response.refreshToken,
            expiresAt: response.accessTokenExpirationDate)
    }
}

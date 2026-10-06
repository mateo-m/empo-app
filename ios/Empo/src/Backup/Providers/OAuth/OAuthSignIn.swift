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

/// The one OAuth sign-in of SPEC 8.10, for every service that uses
/// one.
///
/// AppAuth carries PKCE and the code exchange. Empo hand-rolls the
/// REST of each provider and nothing else, because an SDK would bring
/// a second background session beside Empo's own, per 9.2 and 9.3.
///
/// One class holds the flow for Dropbox, for Google Drive, and for
/// any later service. Ticket 010 states the rule plainly: reuse the
/// shape ticket 009 built, and do not write a second OAuth stack.
@MainActor
final class OAuthSignIn {

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
        let took = session.resumeExternalUserAgentFlow(with: url)
        if took { self.session = nil }
        return took
    }

    /// How long a sign-in waits for the app to reach the foreground.
    private static let activeWait: TimeInterval = 10
    private static let activePollWait: TimeInterval = 0.2

    /// Answers the screen a sheet can come up from.
    ///
    /// AppAuth presents an `ASWebAuthenticationSession`, and that
    /// closes at once when the app is not active yet. A caller that
    /// runs at scene connect is therefore too early, so this waits.
    ///
    /// It answers `nil` when the app never became active.
    static func screenForTheSheet() async -> UIViewController? {
        var left = activeWait
        while left > 0 {
            if UIApplication.shared.applicationState == .active,
                let front = frontViewController(), front.viewIfLoaded?.window != nil
            {
                return front
            }
            try? await Task.sleep(for: .seconds(activePollWait))
            left -= activePollWait
        }
        return nil
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

        let state = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<OIDAuthState?, Error>) in
            session = OIDAuthState.authState(
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
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: state)
            }
        }
        session = nil

        guard let response = state?.lastTokenResponse, let access = response.accessToken else {
            return nil
        }
        return OAuthTokens(
            accessToken: access,
            refreshToken: response.refreshToken,
            expiresAt: response.accessTokenExpirationDate)
    }
}

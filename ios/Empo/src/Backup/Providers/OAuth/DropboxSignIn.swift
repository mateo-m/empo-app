import AppAuth
import Foundation
import GameProbe
import UIKit

/// The Dropbox sign-in of SPEC 8.10 and 9.2.
///
/// AppAuth carries PKCE and the code exchange. Empo hand-rolls the
/// REST of 9.2 and nothing else, because an SDK would bring a second
/// background session beside Empo's own.
///
/// The callback is a custom URL scheme and never an https link. An
/// https callback needs the Associated Domains entitlement, and a
/// sideloaded build does not hold it, per 8.10.
@MainActor
final class DropboxSignIn {

    static let shared = DropboxSignIn()

    /// The rights the app folder needs. A scoped Dropbox app states
    /// them at the authorization, and the console has to hold the
    /// same set.
    static let scopes = [
        "files.content.write",
        "files.content.read",
        "files.metadata.read",
        "account_info.read",
    ]

    /// The app key of 9.2, from `Info.plist`. A PKCE client holds no
    /// secret, so the key is public.
    ///
    /// An empty key is a build that was made without one. Dropbox
    /// then hides from the add flow, the same way 9.1 gates iCloud.
    static var appKey: String {
        let key = Bundle.main.object(forInfoDictionaryKey: "EmpoDropboxAppKey") as? String
        return key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var isConfigured: Bool { !appKey.isEmpty }

    /// The scheme `Info.plist` registers, per 8.10.
    static var redirectURL: URL? {
        URL(string: "db-\(appKey)://oauth2redirect")
    }

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

    /// Signs in and answers the tokens, or `nil` where the user
    /// stopped.
    func signIn(presenting viewController: UIViewController) async throws -> OAuthTokens? {
        guard Self.isConfigured, let redirectURL = Self.redirectURL else {
            throw BackupProviderError.rejected(
                message: "this build carries no Dropbox app key")
        }
        guard let authorization = URL(string: Dropbox.authorizationEndpoint),
            let token = URL(string: Dropbox.tokenEndpoint)
        else {
            throw BackupProviderError.rejected(message: "Empo built no Dropbox URL")
        }

        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: authorization, tokenEndpoint: token)
        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: Self.appKey,
            clientSecret: nil,
            scopes: Self.scopes,
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            // Without offline access Dropbox issues no refresh token,
            // and every overnight run would then ask the user to sign
            // in again.
            additionalParameters: ["token_access_type": "offline"])

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

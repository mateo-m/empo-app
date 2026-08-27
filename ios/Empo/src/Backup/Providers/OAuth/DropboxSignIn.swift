import Foundation
import GameProbe

/// What the Dropbox sign-in of SPEC 8.10 and 9.2 needs.
///
/// `OAuthSignIn` runs the flow. This holds the parts that are about
/// Dropbox: the app key, the scopes, and the callback scheme.
@MainActor
enum DropboxSignIn {

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

    /// What `OAuthSignIn` needs, or `nil` where this build carries no
    /// app key.
    static var service: OAuthService? {
        guard isConfigured, let redirectURL else { return nil }
        guard let authorization = URL(string: Dropbox.authorizationEndpoint),
            let token = URL(string: Dropbox.tokenEndpoint)
        else {
            return nil
        }
        return OAuthService(
            authorizationEndpoint: authorization,
            tokenEndpoint: token,
            clientId: appKey,
            redirectURL: redirectURL,
            scopes: scopes,
            // Without offline access Dropbox issues no refresh token,
            // and every overnight run would then ask the user to sign
            // in again.
            additionalParameters: ["token_access_type": "offline"])
    }
}

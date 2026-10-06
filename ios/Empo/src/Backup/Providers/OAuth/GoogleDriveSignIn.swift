import Foundation
import GameProbe

/// What the Google Drive sign-in of SPEC 8.10 and 9.3 needs.
///
/// `OAuthSignIn` runs the flow, the same one ticket 009 built for
/// Dropbox. This holds the parts that are about Drive: the client id,
/// the one scope, and the reversed-client-id callback scheme.
@MainActor
enum GoogleDriveSignIn {

    /// `drive.file` alone, per 9.3. It is non-sensitive, so no scope
    /// verification and no CASA assessment apply.
    static let scopes = [GoogleDrive.scope]

    /// The iOS OAuth client id of 9.3, from `Info.plist`. A PKCE
    /// client holds no secret, so the id is public.
    ///
    /// An empty id is a build that was made without one. Google Drive
    /// then hides from the add flow, the same way 9.1 gates iCloud
    /// and 9.2 gates Dropbox.
    static var clientId: String {
        let id = Bundle.main.object(forInfoDictionaryKey: "EmpoGoogleDriveClientId") as? String
        return id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Whether this build can open Google Drive at all.
    ///
    /// The id has to be there and it has to carry the form Google
    /// gives an iOS client, because the callback scheme is built from
    /// it. An id in another form has no scheme, and a sign-in that
    /// started would never come back.
    static var isConfigured: Bool { redirectURL != nil }

    /// The scheme `Info.plist` registers, per 8.10. Google gives an
    /// iOS client the reversed form of its own id.
    static var redirectURL: URL? {
        GoogleDrive.redirectURL(clientId: clientId)
    }

    /// What `OAuthSignIn` needs, or `nil` where this build carries no
    /// client id.
    static var service: OAuthService? {
        guard let redirectURL else { return nil }
        guard let authorization = URL(string: GoogleDrive.authorizationEndpoint),
            let token = URL(string: GoogleDrive.tokenEndpoint)
        else {
            return nil
        }
        return OAuthService(
            authorizationEndpoint: authorization,
            tokenEndpoint: token,
            clientId: clientId,
            redirectURL: redirectURL,
            scopes: scopes,
            // Google issues a refresh token only when the request
            // asks for offline access, and only on a consent the user
            // gave this time. Without both, every overnight run would
            // ask the user to sign in again.
            additionalParameters: ["access_type": "offline", "prompt": "consent"])
    }
}

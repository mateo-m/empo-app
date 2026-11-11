import Foundation

/// The answer of an OAuth token endpoint to a refresh.
public enum OAuthRefresh {

    /// One failed refresh onto one error kind.
    ///
    /// Only `invalid_grant` means the refresh token is dead. RFC 6749
    /// section 5.2 sends it with 400. Dropbox answers a revoked token
    /// with 400 `invalid_grant`
    /// (https://github.com/dropbox/dropbox-sdk-dotnet/issues/232), and
    /// Google documents `invalid_grant` for an expired or revoked one
    /// (https://developers.google.com/identity/protocols/oauth2/native-app).
    public static func error(
        kind: BackupProviderKind, status: Int, body: Data, retryAfterHeader: String?
    ) -> BackupProviderError {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = root?["error"] as? String
        if status == 400 || status == 401, code == "invalid_grant" { return .authExpired }
        switch status {
        case 429:
            return .throttled(
                retryAfter: kind == .googleDrive
                    ? RetryWait.seconds(retryAfter: retryAfterHeader, attempt: 1)
                    : Dropbox.retryAfterSeconds(retryAfterHeader))
        case 500..<600:
            return .serverError(status: status)
        default:
            return .refusal(
                by: kind == .googleDrive ? "Google Drive" : "Dropbox",
                said: root?["error_description"] as? String ?? "")
        }
    }
}

import Foundation
import GameProbe

/// Which Google Drive targets this build can open, per SPEC 8.8 and
/// 9.3.
///
/// `OAuthProviderGate` holds the rule, which is the one ticket 009
/// wrote for Dropbox. This states the service.
@MainActor
final class GoogleDriveGate: OAuthProviderGate {

    static let shared = GoogleDriveGate()

    static let kind = BackupProviderKind.googleDrive
    static var service: OAuthService? { GoogleDriveSignIn.service }
    static let noKeyLine = "this build carries no Google Drive client id"
    static let noTokenLine = "sign in to Google Drive to use this target"

    var stores: [String: OAuthTokenStore] = [:]

    private init() {}

    static func makeTarget(tokens: OAuthTokenStore) -> GoogleDriveTarget {
        GoogleDriveTarget(tokens: tokens)
    }
}

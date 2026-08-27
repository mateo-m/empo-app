import Foundation
import GameProbe

/// Which Dropbox targets this build can open, per SPEC 8.8 and 9.2.
///
/// `OAuthProviderGate` holds the rule. This states the service.
@MainActor
final class DropboxGate: OAuthProviderGate {

    static let shared = DropboxGate()

    static let kind = BackupProviderKind.dropbox
    static var service: OAuthService? { DropboxSignIn.service }
    static let noKeyLine = "this build carries no Dropbox app key"
    static let noTokenLine = "sign in to Dropbox to use this target"

    var stores: [String: OAuthTokenStore] = [:]

    private init() {}

    static func makeTarget(tokens: OAuthTokenStore) -> DropboxTarget {
        DropboxTarget(tokens: tokens)
    }
}

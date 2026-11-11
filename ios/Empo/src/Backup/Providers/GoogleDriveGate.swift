import Foundation
import GameProbe

@MainActor
final class GoogleDriveGate: OAuthProviderGate {

    static let shared = GoogleDriveGate()

    static let kind = BackupProviderKind.googleDrive
    static var service: OAuthService? { GoogleDriveSignIn.service }
    static let noKeyLine = "this build carries no Google Drive client id"
    static let noTokenLine = "sign in to Google Drive to use this location"

    var stores: [String: OAuthTokenStore] = [:]
    var targets: [String: GoogleDriveTarget] = [:]

    private init() {}

    static func makeTarget(tokens: OAuthTokenStore) -> GoogleDriveTarget {
        GoogleDriveTarget(tokens: tokens)
    }
}

import Foundation
import GameProbe

/// What one OAuth target keeps in the Keychain, per SPEC 8.8.
///
/// The refresh token is the part that matters. Dropbox hands out an
/// access token that expires in about four hours, and a backup runs
/// overnight, so a run that could not refresh would stop every night.
///
/// This value never leaves the Keychain. It never enters
/// `targets.json`, a backup set, a snapshot, or a backup package, per
/// 6.7 and 8.8, and it never rides the sync document of section 10.
struct OAuthTokens: Codable, Equatable, Sendable {

    var accessToken: String
    /// `nil` where the service issued no refresh token. Dropbox
    /// issues one only when the authorization asked for offline
    /// access, so a nil here is a sign-in that has to be redone.
    var refreshToken: String?
    /// When the access token dies, or `nil` where the service stated
    /// no lifetime.
    var expiresAt: Date?

    /// How long before the stated death a token counts as dead.
    ///
    /// A token that dies while a 2 GB upload is in flight costs the
    /// whole upload, so the refresh happens early.
    static let earlyRefresh: TimeInterval = 5 * 60

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(Self.earlyRefresh) >= expiresAt
    }

    // MARK: - The Keychain

    static func read(targetId: String) -> OAuthTokens? {
        guard let text = try? BackupKeychain.secret(targetId: targetId) else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: Data(text.utf8))
    }

    func write(targetId: String) throws {
        let data = try JSONEncoder().encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BackupKeychain.Failure.notUTF8
        }
        try BackupKeychain.setSecret(text, targetId: targetId)
    }
}

import Foundation
import GameProbe

/// Where one WebDAV target keeps its server and its password, per
/// SPEC 6.7 and 9.5.
///
/// There is no browser step and no token to refresh. The user types
/// an address, a user name, and a password once, and they stay until
/// the user changes them. So the whole `WebDAVConnection` rides the
/// one Keychain item of 6.7, as JSON.
///
/// The record also carries whether this server answered the space
/// query of RFC 4331, because 9.7 makes that a fact about the server
/// and not about the provider. `targets.json` carries the label, the
/// provider kind, and the root path. It never carries the password,
/// per 8.8.
enum WebDAVConnectionStore {

    static func connection(targetId: String) -> WebDAVConnection? {
        guard let text = try? BackupKeychain.secret(targetId: targetId),
            let data = text.data(using: .utf8)
        else { return nil }
        return try? WebDAVConnection.decode(json: data)
    }

    static func write(_ connection: WebDAVConnection, targetId: String) throws {
        let data = try connection.jsonData()
        guard let text = String(data: data, encoding: .utf8) else {
            throw BackupKeychain.Failure.notUTF8
        }
        try BackupKeychain.setSecret(text, targetId: targetId)
    }

    /// Removing a target removes its password, per 8.8.
    static func remove(targetId: String) throws {
        try BackupKeychain.removeSecret(targetId: targetId)
    }
}

import Foundation
import GameProbe

/// Where one S3 target keeps its bucket and its access key, per SPEC
/// 6.7 and 9.4.
///
/// There is no browser step and no token to refresh. The user types a
/// static access key and secret once, and they stay until the user
/// changes them. So the whole `S3Connection` rides the one Keychain
/// item of 6.7, as JSON.
///
/// `targets.json` carries the label, the provider kind, and the root
/// path. It never carries the key, per 8.8.
enum S3ConnectionStore {

    static func connection(targetId: String) -> S3Connection? {
        guard let text = try? BackupKeychain.secret(targetId: targetId),
            let data = text.data(using: .utf8)
        else { return nil }
        return try? S3Connection.decode(json: data)
    }

    static func write(_ connection: S3Connection, targetId: String) throws {
        let data = try connection.jsonData()
        guard let text = String(data: data, encoding: .utf8) else {
            throw BackupKeychain.Failure.notUTF8
        }
        try BackupKeychain.setSecret(text, targetId: targetId)
    }

    /// Removing a target removes its key, per 8.8.
    static func remove(targetId: String) throws {
        try BackupKeychain.removeSecret(targetId: targetId)
    }
}

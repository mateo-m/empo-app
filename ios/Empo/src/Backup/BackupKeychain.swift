import Foundation
import GameProbe
import Security

/// The Keychain items of SPEC 6.7: the namespace id and every target
/// secret.
///
/// Two attributes are forced by the design, not chosen.
///
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The overnight
///   sweep and the background URLSession both run while the device is
///   locked. `WhenUnlocked` would stall every background run until the
///   user next unlocks the phone, which defeats the schedule.
/// - No `kSecAttrSynchronizable`. A synchronizable namespace id would
///   ride iCloud Keychain to a second device and break the one-writer
///   rule of 5.2. A query that omits the attribute matches
///   non-synchronizable items only, which is what every call here
///   wants.
enum BackupKeychain {

    enum Failure: Error, Equatable {
        case status(OSStatus)
        case notUTF8
    }

    private static let service = "sh.mateo.empo.backup"
    private static let namespaceAccount = "namespace-id"

    /// The namespace id of 5.2 for this install. Makes one on the
    /// first call and gives the same one back after that.
    static func namespaceId() throws -> String {
        if let existing = try string(account: namespaceAccount) {
            return existing
        }
        let fresh = BackupKeys.makeNamespaceId()
        try setString(fresh, account: namespaceAccount)
        return fresh
    }

    /// An OAuth token, a key, or a password for one target. Section 8
    /// states the shape of each.
    static func secret(targetId: String) throws -> String? {
        try string(account: secretAccount(targetId))
    }

    static func setSecret(_ secret: String, targetId: String) throws {
        try setString(secret, account: secretAccount(targetId))
    }

    /// Removing a target removes its secret. The namespace id stays,
    /// because the other targets still write under it.
    static func removeSecret(targetId: String) throws {
        try remove(account: secretAccount(targetId))
    }

    private static func secretAccount(_ targetId: String) -> String {
        "target.\(targetId)"
    }

    // MARK: - The Keychain calls

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func string(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw Failure.notUTF8
        }
        return text
    }

    private static func setString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw Failure.notUTF8 }

        let update: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(
            baseQuery(account: account) as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure.status(updated) }

        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.status(added) }
    }

    private static func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.status(status)
        }
    }
}

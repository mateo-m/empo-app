import CryptoKit
import Foundation
import Security

/// The P-256 key that ties a Patreon sign-in to this device. The server
/// accepts a renewal or a sign-out only with a signature from this key.
enum PlusDeviceKey {

    private enum Key {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    struct UnreadableKey: Error {}

    private static let enclavePrefix = "enclave:"
    private static let softwarePrefix = "software:"

    /// The public key as an uncompressed point, in base64url.
    static func publicKey() throws -> String {
        let key: P256.Signing.PublicKey
        switch try load() {
        case .enclave(let privateKey): key = privateKey.publicKey
        case .software(let privateKey): key = privateKey.publicKey
        }
        return base64URL(key.x963Representation)
    }

    static func sign(_ text: String) throws -> String {
        let message = Data(text.utf8)
        let signature: P256.Signing.ECDSASignature
        switch try load() {
        case .enclave(let privateKey): signature = try privateKey.signature(for: message)
        case .software(let privateKey): signature = try privateKey.signature(for: message)
        }
        return base64URL(signature.rawRepresentation)
    }

    private static func load() throws -> Key {
        if let stored = try BackupKeychain.plusDeviceKey() {
            if stored.hasPrefix(enclavePrefix),
                let data = Data(base64Encoded: String(stored.dropFirst(enclavePrefix.count)))
            {
                return .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data))
            }
            if stored.hasPrefix(softwarePrefix),
                let data = Data(base64Encoded: String(stored.dropFirst(softwarePrefix.count)))
            {
                return .software(try P256.Signing.PrivateKey(rawRepresentation: data))
            }
            // A new key here would cost the device its place in the
            // account's device list.
            throw UnreadableKey()
        }
        // The simulator and Macs without a Secure Enclave keep a software
        // key in a Keychain item that does not leave this device.
        let key: Key
        let stored: String
        if SecureEnclave.isAvailable {
            // Background backups renew the pass while the device is locked.
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil)!
            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            key = .enclave(privateKey)
            stored = enclavePrefix + privateKey.dataRepresentation.base64EncodedString()
        } else {
            let privateKey = P256.Signing.PrivateKey()
            key = .software(privateKey)
            stored = softwarePrefix + privateKey.rawRepresentation.base64EncodedString()
        }
        try BackupKeychain.setPlusDeviceKey(stored)
        return key
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

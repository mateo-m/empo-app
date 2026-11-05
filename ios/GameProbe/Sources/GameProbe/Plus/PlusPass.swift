import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The text is `base64url(payload).base64url(signature)`. The payload
/// is the JSON `{v, sub, plus, iat, exp}`, and the API signs it with
/// Ed25519.
public struct PlusPass: Equatable, Sendable {

    public let includesPlus: Bool
    public let expiresAt: Date

    /// The app asks for a new pass when this much time is left.
    public static let renewalWindow: TimeInterval = 3 * 24 * 60 * 60

    public init?(_ text: String, publicKey: Data) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let payload = Self.data(base64URL: parts[0]),
            let signature = Self.data(base64URL: parts[1]),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
            key.isValidSignature(signature, for: payload),
            let claims = try? JSONDecoder().decode(Claims.self, from: payload),
            claims.v == 1
        else { return nil }
        includesPlus = claims.plus
        expiresAt = Date(timeIntervalSince1970: claims.exp)
    }

    public func grantsPlus(at now: Date) -> Bool {
        includesPlus && now < expiresAt
    }

    public func needsRenewal(at now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) < Self.renewalWindow
    }

    private struct Claims: Decodable {
        let v: Int
        let plus: Bool
        let exp: TimeInterval
    }

    private static func data(base64URL: Substring) -> Data? {
        var text = base64URL.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
}

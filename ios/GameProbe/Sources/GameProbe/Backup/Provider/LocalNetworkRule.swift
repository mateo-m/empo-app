import Foundation

/// Which hosts sit on the local network, where iOS asks the user
/// before the first connection.
public enum LocalNetworkRule {

    public static func asksThePermission(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".local") { return true }
        if host.contains(":") {
            guard let first = host.split(separator: ":").first, first.count == 4,
                let hextet = UInt16(first, radix: 16)
            else { return false }
            // fe80::/10 is link-local, fc00::/7 is unique local.
            return hextet & 0xffc0 == 0xfe80 || hextet & 0xfe00 == 0xfc00
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}

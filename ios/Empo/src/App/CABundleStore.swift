import CryptoKit
import Foundation

/// Keeps the engine's TLS trust store fresh without user involvement.
///
/// The engine verifies game TLS traffic (native HTTP client + Ruby's
/// openssl via SSL_CERT_FILE) against a Mozilla CA bundle. The copy in
/// Assets.bundle is only a first-run seed. Root stores churn slowly,
/// but they do churn, and a bundle frozen at build time eventually
/// bites (the 2021 Let's Encrypt root expiry variety). We do not ask
/// users to care. We refresh silently: download the current bundle
/// from curl.se over URLSession, and prefer the refreshed copy.
/// URLSession trusts the *OS* root store, so the refresh itself can
/// never go stale.
///
/// **Integrity.** The payload must match curl.se's published SHA-256
/// sidecar and look like a plausible PEM bundle (parseable, dozens of
/// certificates) before it replaces anything. On any failure we keep
/// the previous copy. There is no user-visible error surface.
///
/// **Throttle.** At most one *successful* refresh per
/// `refreshInterval`. We write the stamp only when a verified bundle
/// lands. Failed attempts (offline launch, captive portal, server
/// hiccup) retry on the next launch. Each retry is one small GET, so
/// retries until the first success are cheap. The retries also rescue
/// a fresh install whose bundled seed is years old by install time.
enum CABundleStore {

    private static let bundleURL = URL(string: "https://curl.se/ca/cacert.pem")!
    private static let checksumURL = URL(string: "https://curl.se/ca/cacert.pem.sha256")!
    private static let refreshInterval: TimeInterval = 7 * 24 * 3600
    private static let lastRefreshKey = DefaultsKey.caBundleLastRefresh

    /// Minimum root certificates for a payload to be believable. The
    /// real Mozilla bundle carries 100+. Anything tiny is a truncated
    /// download or a captive-portal page.
    private static let minimumCertCount = 50

    private static var refreshedURL: URL? {
        guard
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        return support.appendingPathComponent("CABundle/cacert.pem")
    }

    /// Path the engine should trust: the refreshed copy when we
    /// downloaded one and it still looks valid, the built-in seed
    /// otherwise. Never nil unless the app bundle itself is broken.
    static var effectivePath: String? {
        if let refreshed = refreshedURL,
            let data = try? Data(contentsOf: refreshed),
            looksLikeCABundle(data)
        {
            return refreshed.path
        }
        return Bundle.main.path(
            forResource: "cacert", ofType: "pem", inDirectory: "Assets.bundle")
    }

    /// Fire-and-forget refresh. Safe to call on every launch.
    static func refreshIfStale(onRefresh: @escaping () -> Void) {
        let last = UserDefaults.standard.double(forKey: lastRefreshKey)
        guard Date().timeIntervalSince1970 - last >= refreshInterval else { return }

        Task.detached(priority: .utility) {
            do {
                let (data, _) = try await URLSession.shared.data(from: bundleURL)
                let (checksumData, _) = try await URLSession.shared.data(from: checksumURL)
                guard verifyChecksum(data, sidecar: checksumData),
                    looksLikeCABundle(data),
                    let target = refreshedURL
                else { return }

                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                UserDefaults.standard.set(
                    Date().timeIntervalSince1970, forKey: lastRefreshKey)
                onRefresh()
            } catch {
                // Offline / server hiccup: keep whatever we had and
                // retry next launch.
            }
        }
    }

    /// curl.se sidecar format: "<hex sha256>  cacert.pem".
    private static func verifyChecksum(_ data: Data, sidecar: Data) -> Bool {
        guard
            let line = String(data: sidecar, encoding: .utf8)?
                .split(separator: " ").first
        else { return false }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        return digest == line.lowercased()
    }

    private static func looksLikeCABundle(_ data: Data) -> Bool {
        guard data.count > 50_000, data.count < 5_000_000,
            let text = String(data: data, encoding: .utf8)
        else { return false }
        let begins = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
        let ends = text.components(separatedBy: "-----END CERTIFICATE-----").count - 1
        return begins >= minimumCertCount && begins == ends
    }
}

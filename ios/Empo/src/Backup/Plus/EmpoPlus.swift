import AuthenticationServices
import Foundation
import GameProbe
import Observation
import SwiftUI

/// Whether this device has Empo Plus, from the Patreon sign-in that
/// the Empo API (`api/` in this repo) turns into a signed pass.
///
/// Every backup location except iCloud Drive needs Plus to take new
/// backups. Restores never need it.
@MainActor
@Observable
final class EmpoPlus {

    static let shared = EmpoPlus()

    enum SignInFailure: Error {
        case cancelled
        case server
    }

    static let joinURL = URL(string: "https://www.patreon.com/checkout/mateo_m?rid=29989848")!
    private static let api = URL(string: "https://api.empo.mateo.sh")!
    private static let callbackScheme = "empo"
    private static let publicKey = Data(
        base64Encoded: "/Y4z9rhhNjRsPdXBEnhucGbDQDAuyMUupgqaPA+qTrA=")!

    private(set) var pass: PlusPass?
    private var renewal: String?
    private var renewing: Task<Void, Never>?

    private init() {
        let stored = try? BackupKeychain.plus()
        renewal = stored?.renewal
        pass = stored.flatMap { PlusPass($0.pass, publicKey: Self.publicKey) }
    }

    var isSignedIn: Bool { renewal != nil }

    var hasPlus: Bool { pass?.grantsPlus(at: .now) ?? false }

    func signIn(using session: WebAuthenticationSession) async throws(SignInFailure) {
        let state = UUID().uuidString
        var start = URLComponents(
            url: Self.api.appending(path: "patreon/start"), resolvingAgainstBaseURL: false)!
        start.queryItems = [URLQueryItem(name: "state", value: state)]

        let callback: URL
        do {
            callback = try await session.authenticate(
                using: start.url!, callback: .customScheme(Self.callbackScheme),
                additionalHeaderFields: [:])
        } catch ASWebAuthenticationSessionError.canceledLogin {
            throw .cancelled
        } catch {
            throw .server
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == state else { throw .server }
        if let error = value("error") {
            // Patreon sends `access_denied` when the user presses Deny.
            throw error == "server" ? .server : .cancelled
        }
        guard let pass = value("pass"), let renewal = value("renewal"),
            keep(pass: pass, renewal: renewal)
        else { throw .server }
    }

    /// Asks the API for a new pass when the stored one ends in less
    /// than 3 days, or always with `force`.
    func renew(force: Bool = false) async {
        if let renewing { return await renewing.value }
        guard let renewal, force || pass?.needsRenewal(at: .now) ?? true else { return }
        let task = Task { await self.renew(with: renewal) }
        renewing = task
        await task.value
        renewing = nil
    }

    func signOut() {
        try? BackupKeychain.removePlus()
        pass = nil
        renewal = nil
    }

    // Patreon refresh tokens are single use. Two renewals with the
    // same token sign the user out, so `renew` runs one at a time.
    private func renew(with renewal: String) async {
        var request = URLRequest(url: Self.api.appending(path: "patreon/renew"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONEncoder().encode(["renewal": renewal])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let status = (response as? HTTPURLResponse)?.statusCode,
            // A sign-out or a new sign-in during the call wins.
            renewal == self.renewal
        else { return }
        if status == 401 {
            signOut()
            return
        }
        guard status == 200,
            let issued = try? JSONDecoder().decode([String: String].self, from: data),
            let pass = issued["pass"], let next = issued["renewal"]
        else { return }
        keep(pass: pass, renewal: next)
    }

    @discardableResult
    private func keep(pass text: String, renewal: String) -> Bool {
        guard let pass = PlusPass(text, publicKey: Self.publicKey),
            (try? BackupKeychain.setPlus(pass: text, renewal: renewal)) != nil
        else { return false }
        self.pass = pass
        self.renewal = renewal
        return true
    }
}

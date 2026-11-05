import AuthenticationServices
import Foundation
import GameProbe
import Observation
import SwiftUI

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
    private var renewing: Task<Bool, Never>?

    private init() {
        let stored = try? BackupKeychain.plus()
        renewal = stored?.renewal
        pass = stored?.pass.flatMap { PlusPass($0, publicKey: Self.publicKey) }
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

    /// Returns false when the API did not answer.
    @discardableResult
    func renew(force: Bool = false) async -> Bool {
        if let renewing { return await renewing.value }
        guard let renewal, force || pass?.needsRenewal(at: .now) ?? true else { return true }
        let task = Task { await self.renew(with: renewal) }
        renewing = task
        defer { renewing = nil }
        return await task.value
    }

    func signOut() {
        try? BackupKeychain.removePlus()
        pass = nil
        renewal = nil
    }

    // Patreon refresh tokens are single use. Two renewals with the
    // same token sign the user out, so `renew` runs one at a time.
    private func renew(with renewal: String) async -> Bool {
        var request = URLRequest(url: Self.api.appending(path: "patreon/renew"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONEncoder().encode(["renewal": renewal])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let status = (response as? HTTPURLResponse)?.statusCode,
            // A sign-out or a new sign-in during the call wins.
            renewal == self.renewal
        else { return false }
        if status == 401 {
            // Patreon refused the sign-in. The pass stays good until it
            // ends, and the Plus screen asks for a new sign-in.
            try? BackupKeychain.removePlusRenewal()
            self.renewal = nil
            return true
        }
        guard status == 200,
            let issued = try? JSONDecoder().decode([String: String].self, from: data),
            let pass = issued["pass"], let next = issued["renewal"]
        else { return false }
        return keep(pass: pass, renewal: next)
    }

    @discardableResult
    private func keep(pass text: String, renewal: String) -> Bool {
        guard let pass = PlusPass(text, publicKey: Self.publicKey) else { return false }
        try? BackupKeychain.setPlus(pass: text, renewal: renewal)
        self.pass = pass
        self.renewal = renewal
        return true
    }
}

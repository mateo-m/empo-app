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
        /// The account is signed in on the most devices it can have.
        case tooManyDevices
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

    var hasPlus: Bool { (pass?.grantsPlus(at: .now) ?? false) || PlusStore.shared.isSubscribed }

    /// With `replace`, the server signs out the other devices of the
    /// account when it is at its device limit.
    func signIn(using session: WebAuthenticationSession, replace: Bool = false) async throws(SignInFailure) {
        let state = UUID().uuidString
        guard let device = try? PlusDeviceKey.publicKey() else { throw .server }
        var start = URLComponents(
            url: Self.api.appending(path: "patreon/start"), resolvingAgainstBaseURL: false)!
        start.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "device", value: device),
            URLQueryItem(name: "replace", value: replace ? "true" : "false"),
        ]

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
            switch error {
            case "server": throw .server
            case "too_many_devices": throw .tooManyDevices
            default: throw .cancelled
            }
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
        if let renewal {
            // The server deletes its copy of the Patreon sign-in. When
            // the call fails, the server deletes it after 90 days.
            if let request = Self.signed("sign-out", renewal: renewal) {
                Task { _ = try? await URLSession.shared.data(for: request) }
            }
        }
        try? BackupKeychain.removePlus()
        pass = nil
        renewal = nil
    }

    private struct Signed: Encodable {
        let renewal: String
        let time: Int64
        let signature: String
    }

    /// The server takes a call only when its time is later than the time
    /// of the last call, so a copied call can't run again.
    private static func signed(_ action: String, renewal: String) -> URLRequest? {
        let time = Int64(Date.now.timeIntervalSince1970 * 1000)
        guard let signature = try? PlusDeviceKey.sign(action, time: time) else { return nil }
        var request = URLRequest(url: api.appending(path: "patreon/\(action)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONEncoder().encode(
            Signed(renewal: renewal, time: time, signature: signature))
        return request
    }

    private func renew(with renewal: String) async -> Bool {
        guard let request = Self.signed("renew", renewal: renewal),
            let (data, response) = try? await URLSession.shared.data(for: request),
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
            let pass = issued["pass"]
        else { return false }
        return keep(pass: pass, renewal: renewal)
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

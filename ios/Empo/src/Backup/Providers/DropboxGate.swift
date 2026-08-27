import Foundation
import GameProbe
import UIKit

/// Which Dropbox targets this build can open, per SPEC 8.8 and 9.2.
///
/// Two things have to hold. The build needs the app key of 9.2, and
/// the target needs its tokens in the Keychain. A target that has a
/// descriptor and no tokens is the placeholder of 8.8: it keeps its
/// row, disabled, until the user signs in.
@MainActor
final class DropboxGate {

    static let shared = DropboxGate()

    /// One store per target, so four transfers in flight share one
    /// refresh instead of making four.
    private var stores: [String: OAuthTokenStore] = [:]

    private init() {}

    /// Whether the add flow of 13.7 shows Dropbox at all.
    var showsInAddFlow: Bool { DropboxSignIn.isConfigured }

    /// What one target's row reads when it cannot open, per 13.5.
    static let noKeyLine = "this build carries no Dropbox app key"
    static let noTokenLine = "sign in to Dropbox to use this target"

    func cannotOpenLine(for target: TargetDescriptor) -> String? {
        guard target.provider == .dropbox else { return nil }
        if !DropboxSignIn.isConfigured { return Self.noKeyLine }
        if OAuthTokenStore.tokens(targetId: target.id) == nil { return Self.noTokenLine }
        return nil
    }

    /// The provider one descriptor opens, or `nil` where it cannot.
    func target(for descriptor: TargetDescriptor) -> DropboxTarget? {
        guard descriptor.provider == .dropbox, DropboxSignIn.isConfigured else { return nil }
        guard let store = store(for: descriptor.id) else { return nil }
        return DropboxTarget(tokens: store)
    }

    private func store(for targetId: String) -> OAuthTokenStore? {
        if let existing = stores[targetId] { return existing }
        guard let tokens = OAuthTokenStore.tokens(targetId: targetId) else { return nil }
        guard let endpoint = URL(string: Dropbox.tokenEndpoint) else { return nil }

        let store = OAuthTokenStore(
            targetId: targetId,
            service: OAuthTokenStore.Service(
                tokenEndpoint: endpoint, clientId: DropboxSignIn.appKey),
            tokens: tokens)
        stores[targetId] = store
        return store
    }

    /// Signs in and writes the tokens for one target.
    ///
    /// It runs at add time and again after the auth loss of 8.10.
    /// The caller runs the permission check of 8.7 after it, because
    /// a re-sign-in reruns the check.
    @discardableResult
    func signIn(
        targetId: String, presenting viewController: UIViewController
    ) async throws -> Bool {
        guard let tokens = try await DropboxSignIn.shared.signIn(presenting: viewController) else {
            return false
        }
        if let store = stores[targetId] {
            try await store.replace(with: tokens)
        } else {
            try tokens.write(targetId: targetId)
            _ = store(for: targetId)
        }
        return true
    }

    /// Forgets a target's store. Removing a target removes its
    /// secret, per 8.8, and this drops what the process still holds.
    func forget(targetId: String) {
        stores[targetId] = nil
    }
}

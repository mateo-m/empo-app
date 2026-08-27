import Foundation
import GameProbe
import UIKit

/// Which targets of one OAuth service this build can open, per SPEC
/// 8.8.
///
/// Two things have to hold. The build needs the client id of its
/// service, and the target needs its tokens in the Keychain. A target
/// that has a descriptor and no tokens is the placeholder of 8.8: it
/// keeps its row, disabled, until the user signs in.
///
/// Dropbox and Google Drive answer the same way, so the rule lives
/// here once. Each gate states its service and builds its own
/// provider.
@MainActor
protocol OAuthProviderGate: AnyObject {

    associatedtype Target: BackupProvider

    /// The service of section 9 this gate opens.
    static var kind: BackupProviderKind { get }
    /// What a sign-in needs, or `nil` where this build carries no
    /// client id.
    static var service: OAuthService? { get }
    /// What one target's row reads when the build carries no client
    /// id, per 13.5.
    static var noKeyLine: String { get }
    /// What it reads when the target holds no tokens yet.
    static var noTokenLine: String { get }

    /// One store per target, so four transfers in flight share one
    /// refresh instead of making four.
    var stores: [String: OAuthTokenStore] { get set }

    static func makeTarget(tokens: OAuthTokenStore) -> Target
}

extension OAuthProviderGate {

    /// Whether the add flow of 13.7 shows this service at all.
    var showsInAddFlow: Bool { Self.service != nil }

    func cannotOpenLine(for target: TargetDescriptor) -> String? {
        guard target.provider == Self.kind else { return nil }
        if Self.service == nil { return Self.noKeyLine }
        if OAuthTokenStore.tokens(targetId: target.id) == nil { return Self.noTokenLine }
        return nil
    }

    /// The provider one descriptor opens, or `nil` where it cannot.
    func target(for descriptor: TargetDescriptor) -> Target? {
        guard descriptor.provider == Self.kind, Self.service != nil else { return nil }
        guard let store = store(for: descriptor.id) else { return nil }
        return Self.makeTarget(tokens: store)
    }

    func store(for targetId: String) -> OAuthTokenStore? {
        if let existing = stores[targetId] { return existing }
        guard let service = Self.service else { return nil }
        guard let tokens = OAuthTokenStore.tokens(targetId: targetId) else { return nil }

        let store = OAuthTokenStore(
            targetId: targetId,
            service: OAuthTokenStore.Service(
                tokenEndpoint: service.tokenEndpoint, clientId: service.clientId),
            tokens: tokens)
        stores[targetId] = store
        return store
    }

    /// Signs in and writes the tokens for one target.
    ///
    /// It runs at add time and again after the auth loss of 8.10. The
    /// caller runs the permission check of 8.7 after it, because a
    /// re-sign-in reruns the check.
    @discardableResult
    func signIn(
        targetId: String, presenting viewController: UIViewController
    ) async throws -> Bool {
        guard let service = Self.service else {
            throw BackupProviderError.rejected(message: Self.noKeyLine)
        }
        guard
            let tokens = try await OAuthSignIn.shared.signIn(
                service: service, presenting: viewController)
        else {
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

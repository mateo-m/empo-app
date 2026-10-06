import Foundation
import GameProbe

/// Which WebDAV targets this build can open, per SPEC 8.8 and 9.5.
///
/// The OAuth gates ask two questions: does the build carry a client
/// id, and does the target hold tokens. WebDAV asks one, as S3 does.
/// The build carries no account of its own, because the user types
/// theirs. So a target opens when the Keychain holds its
/// `WebDAVConnection` and it does not when the Keychain holds
/// nothing.
///
/// A device that took `targets.json` from a sync and no Keychain item
/// shows the target placeholder of 8.8.
///
/// This gate carries one job the other four do not: it writes back
/// what the permission check of 8.7 learned about the server. RFC
/// 4331 is answered by some servers and not by others, so
/// `canQueryQuota` is a per-target fact, per 9.7.
@MainActor
final class WebDAVGate {

    static let shared = WebDAVGate()

    static let kind = BackupProviderKind.webdav
    /// What the row reads while the target holds no password, per
    /// 13.5.
    static let noPasswordLine = "type the password of this server to use this target"

    /// One target per id, so four transfers in flight share one
    /// record of what is already committed and which collections are
    /// already there.
    private var targets: [String: WebDAVTarget] = [:]

    private init() {}

    func cannotOpenLine(for descriptor: TargetDescriptor) -> String? {
        guard descriptor.provider == Self.kind else { return nil }
        return WebDAVConnectionStore.connection(targetId: descriptor.id) == nil
            ? Self.noPasswordLine : nil
    }

    /// The provider one descriptor opens, or `nil` where it holds no
    /// password yet.
    func target(for descriptor: TargetDescriptor) -> WebDAVTarget? {
        guard descriptor.provider == Self.kind else { return nil }
        if let existing = targets[descriptor.id] { return existing }
        guard let connection = WebDAVConnectionStore.connection(targetId: descriptor.id) else {
            return nil
        }
        let target = WebDAVTarget(connection: connection)
        targets[descriptor.id] = target
        return target
    }

    /// Writes the password and opens the target. The add flow of 13.7
    /// calls it, and the permission check of 8.7 runs after it.
    @discardableResult
    func connect(_ connection: WebDAVConnection, targetId: String) throws -> WebDAVTarget {
        try WebDAVConnectionStore.write(connection, targetId: targetId)
        let target = WebDAVTarget(connection: connection)
        targets[targetId] = target
        return target
    }

    /// Records what the permission check of 8.7 learned, per 9.7.
    ///
    /// The flags of 8.3 are fixed for the life of a provider, so a
    /// changed answer builds the target again. The check runs at add
    /// time and after a re-sign-in, and nowhere else.
    func rememberTheSpaceQuery(_ answers: Bool, targetId: String) {
        guard var connection = WebDAVConnectionStore.connection(targetId: targetId),
            connection.server.answersQuota != answers
        else { return }
        connection.server.answersQuota = answers
        guard (try? WebDAVConnectionStore.write(connection, targetId: targetId)) != nil else {
            return
        }
        targets[targetId] = WebDAVTarget(connection: connection)
    }

    /// Forgets what this process holds for a target. Removing a
    /// target removes its password, per 8.8.
    func forget(targetId: String) {
        targets[targetId] = nil
    }
}

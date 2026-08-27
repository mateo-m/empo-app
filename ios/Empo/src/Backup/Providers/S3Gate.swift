import Foundation
import GameProbe

/// Which S3 targets this build can open, per SPEC 8.8 and 9.4.
///
/// The OAuth gates ask two questions: does the build carry a client
/// id, and does the target hold tokens. S3 asks one. The build
/// carries no key of its own, because the user types theirs. So a
/// target opens when the Keychain holds its `S3Connection` and it
/// does not when the Keychain holds nothing.
///
/// A device that took `targets.json` from a sync and no Keychain item
/// shows the target placeholder of 8.8.
@MainActor
final class S3Gate {

    static let shared = S3Gate()

    static let kind = BackupProviderKind.s3
    /// What the row reads while the target holds no key, per 13.5.
    static let noKeyLine = "type the access key of this bucket to use this target"

    /// One target per id, so four transfers in flight share one
    /// record of what is already committed.
    private var targets: [String: S3Target] = [:]

    /// The two numbers a device check lowers, per ticket 011. The
    /// launch flag sets them, and a normal run leaves them at the
    /// 5 GiB and the 32 MiB of 9.4.
    private var singleUploadLimit = S3.singleUploadLimitBytes
    private var partBase = S3.defaultPartBytes

    private init() {}

    func cannotOpenLine(for descriptor: TargetDescriptor) -> String? {
        guard descriptor.provider == Self.kind else { return nil }
        return S3ConnectionStore.connection(targetId: descriptor.id) == nil ? Self.noKeyLine : nil
    }

    /// The provider one descriptor opens, or `nil` where it holds no
    /// key yet.
    func target(for descriptor: TargetDescriptor) -> S3Target? {
        guard descriptor.provider == Self.kind else { return nil }
        if let existing = targets[descriptor.id] { return existing }
        guard let connection = S3ConnectionStore.connection(targetId: descriptor.id) else {
            return nil
        }
        let target = S3Target(
            connection: connection,
            singleUploadLimit: singleUploadLimit,
            partBase: partBase)
        targets[descriptor.id] = target
        return target
    }

    /// Writes the key and opens the target. The add flow of 13.7
    /// calls it, and the permission check of 8.7 runs after it.
    @discardableResult
    func connect(_ connection: S3Connection, targetId: String) throws -> S3Target {
        try S3ConnectionStore.write(connection, targetId: targetId)
        let target = S3Target(
            connection: connection,
            singleUploadLimit: singleUploadLimit,
            partBase: partBase)
        targets[targetId] = target
        return target
    }

    /// Forgets what this process holds for a target. Removing a
    /// target removes its key, per 8.8.
    func forget(targetId: String) {
        targets[targetId] = nil
    }

    /// Lowers the two upload numbers so the multipart path of 9.4
    /// runs with a file a phone can write, per the device check of
    /// ticket 011.
    func useSmallParts(singleUploadLimit: Int64, partBase: Int64) {
        self.singleUploadLimit = singleUploadLimit
        self.partBase = partBase
        targets.removeAll()
    }
}

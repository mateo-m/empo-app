import Foundation
import GameProbe

/// The configured backup targets of SPEC 8.8, and the provider each
/// one opens.
///
/// `TargetDescriptorFile` in GameProbe holds the file and its shape.
/// This file answers the one question only iOS can: which provider a
/// descriptor opens right now. Today that is iCloud Drive alone.
/// Tickets 009 to 013 add the rest.
@MainActor
enum BackupTargets {

    static func load() -> [TargetDescriptor] {
        let file = try? TargetDescriptorFile.read(applicationSupport: BackupRoot.applicationSupport)
        return file?.targets ?? []
    }

    static func save(_ targets: [TargetDescriptor]) throws {
        try TargetDescriptorFile(targets: targets)
            .write(applicationSupport: BackupRoot.applicationSupport)
    }

    /// Adds one target, or replaces the one that carries its id.
    static func add(_ target: TargetDescriptor) throws {
        var targets = load().filter { $0.id != target.id }
        targets.append(target)
        try save(targets)
    }

    /// The provider a descriptor opens, or `nil` where this build
    /// cannot open it.
    ///
    /// A nil answer is not a failure. iCloud Drive answers nil while
    /// its runtime gate is closed, per 9.1, and the target keeps its
    /// row.
    static func provider(for target: TargetDescriptor) async -> (any BackupProvider)? {
        switch target.provider {
        case .iCloudDrive:
            return await ICloudDriveGate.shared.target()
        case .dropbox, .googleDrive, .s3, .webdav, .sftp:
            // Tickets 009 to 013.
            return nil
        }
    }

    /// The size threshold of every configured target, which the ask
    /// of 3.5 reads.
    static func thresholds() -> [BackupTargetThreshold] {
        load().map {
            BackupTargetThreshold(
                targetId: $0.id, displayName: $0.label, overrideBytes: $0.sizeThresholdBytes)
        }
    }

    // MARK: - The add flow

    /// Runs the permission check of 8.7 against a provider, then adds
    /// the target when the check allows it.
    ///
    /// Ticket 016 renders the sheet. This is the part below it: the
    /// four steps in order, and the quota answer that sets
    /// `canQueryQuota` for this target, per 8.3 and 9.7.
    static func addAfterPermissionCheck(
        _ target: TargetDescriptor, provider: some BackupProvider
    ) async throws -> PermissionCheckResult {
        let result = await PermissionCheck.run(
            on: provider, scratchDirectory: BackupRoot.staging)
        guard result.allowsAdd else { return result }
        try add(target)
        return result
    }
}

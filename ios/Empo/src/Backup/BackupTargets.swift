import Foundation
import GameProbe

/// The configured backup targets of SPEC 8.8, and the provider each
/// one opens.
///
/// `TargetDescriptorFile` in GameProbe holds the file and its shape.
/// This file answers the one question only iOS can: which provider a
/// descriptor opens right now. Today that is iCloud Drive, Dropbox,
/// Google Drive, the S3-compatible services, and WebDAV.
@MainActor
enum BackupTargets {

    static func load() -> [TargetDescriptor] {
        let file = try? TargetDescriptorFile.read(
            applicationSupport: BackupRoot.layout.applicationSupport)
        return file?.targets ?? []
    }

    /// Changes the targets on the file and not on a copy.
    ///
    /// A sync pass runs for seconds, and the user adds or pauses a
    /// target in the middle of one. A caller that read the list
    /// before the pass and wrote it back after would put the old
    /// list back, so every change reads the file again first.
    static func update(_ change: (inout [TargetDescriptor]) -> Void) throws {
        let stored = load()
        var targets = stored
        change(&targets)
        guard targets != stored else { return }
        try TargetDescriptorFile(targets: targets)
            .write(applicationSupport: BackupRoot.layout.applicationSupport)
        BackupBadges.shared.invalidate()
    }

    /// Adds one target, or replaces the one that carries its id.
    static func add(_ target: TargetDescriptor) throws {
        try update { targets in
            targets.removeAll { $0.id == target.id }
            targets.append(target)
        }
        SyncJoin.startAGroup()
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
        case .dropbox:
            return DropboxGate.shared.target(for: target)
        case .googleDrive:
            return GoogleDriveGate.shared.target(for: target)
        case .s3:
            return S3Gate.shared.target(for: target)
        case .webdav:
            return WebDAVGate.shared.target(for: target)
        case .sftp:
            // Out of v1, per ticket 013. The service list offers no
            // SFTP row, so no descriptor carries this kind.
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
            on: provider,
            probePath: PermissionCheck.makeProbePath(root: target.root),
            scratchDirectory: BackupRoot.layout.staging)
        guard result.allowsAdd else { return result }
        // WebDAV and SFTP answer the space query on some servers and
        // not on others, so the check that just ran is what sets
        // `canQueryQuota` for this target, per 8.3 and 9.7.
        if target.provider == .webdav {
            WebDAVGate.shared.rememberTheSpaceQuery(result.canQueryQuota, targetId: target.id)
        }
        try add(target)
        return result
    }
}

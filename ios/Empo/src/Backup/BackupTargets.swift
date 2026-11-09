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

    /// A damaged file throws. A caller that read it as "no targets"
    /// and wrote the list back would delete every target.
    static func read() throws -> [TargetDescriptor] {
        let data: Data
        do {
            data = try Data(contentsOf: BackupRoot.layout.targetsFile)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return try TargetDescriptorFile.decode(json: data).targets
    }

    /// For the readers that only show or skip targets. They see no
    /// target when the file is damaged, and nothing writes.
    static func load() -> [TargetDescriptor] {
        do {
            return try read()
        } catch {
            BackupLog.line("BackupTargets", "targets.json was not read: \(error)")
            return []
        }
    }

    /// Moves a damaged file aside, so that the user can add the
    /// targets again. The damaged copy stays beside it.
    static func setAsideTheDamagedFile() throws {
        let file = BackupRoot.layout.targetsFile
        let stamp = Int(Date().timeIntervalSince1970)
        try FileManager.default.moveItem(
            at: file, to: file.deletingPathExtension().appendingPathExtension("damaged-\(stamp).json"))
        BackupBadges.shared.invalidate()
    }

    /// Restores use `load()`, so they still read from every target.
    static func writable() -> [TargetDescriptor] {
        let hasPlus = EmpoPlus.shared.hasPlus
        return load().filter { !$0.isPaused && (hasPlus || !$0.provider.needsPlus) }
    }

    /// Changes the targets on the file and not on a copy.
    ///
    /// A sync pass runs for seconds, and the user adds or pauses a
    /// target in the middle of one. A caller that read the list
    /// before the pass and wrote it back after would put the old
    /// list back, so every change reads the file again first.
    static func update(_ change: (inout [TargetDescriptor]) -> Void) throws {
        let stored = try read()
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
            if let at = targets.firstIndex(where: { $0.id == target.id }) {
                targets[at] = target
            } else {
                targets.append(target)
            }
        }
        try SyncStore.update { $0.keep(targetId: target.id) }
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
        }
    }

    /// Drops the provider and the connection this process holds for a
    /// target, so nothing opens it with a secret that went.
    static func forget(targetId: String) {
        DropboxGate.shared.forget(targetId: targetId)
        GoogleDriveGate.shared.forget(targetId: targetId)
        S3Gate.shared.forget(targetId: targetId)
        WebDAVGate.shared.forget(targetId: targetId)
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
        // WebDAV answers the space query on some servers and
        // not on others, so the check that just ran is what sets
        // `canQueryQuota` for this target, per 8.3 and 9.7.
        if target.provider == .webdav {
            WebDAVGate.shared.rememberTheSpaceQuery(result.canQueryQuota, targetId: target.id)
        }
        try add(target)
        return result
    }

    /// Locations added before Empo read the account take it once.
    static func readTheMissingAccounts() async {
        for target in load() where target.accountName == nil && !target.isPlaceholder {
            guard let reader = await provider(for: target) as? any AccountReading,
                let account = await reader.account()
            else { continue }
            try? update { targets in
                guard let index = targets.firstIndex(where: { $0.id == target.id }) else { return }
                targets[index].take(account)
            }
        }
    }
}

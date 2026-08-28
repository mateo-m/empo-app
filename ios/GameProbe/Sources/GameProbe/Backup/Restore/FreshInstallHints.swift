import Foundation

/// The hints of SPEC 11.4, which tell a fresh install about the
/// targets it has not added yet.
///
/// A hint names a concrete service and the user's own label. It never
/// says "provider", and it never names an account, because the
/// streamed descriptor carries no account hint, per 8.8.
///
/// The root does travel, so a hint for an S3 or a WebDAV target can
/// name the bucket or the path the new install must point at.
public enum FreshInstallHints {

    /// The providers the user runs on hardware of their own, per 5.7
    /// and 13.7.
    public static func isSelfHosted(_ provider: BackupProviderKind) -> Bool {
        switch provider {
        case .s3, .webdav, .sftp: return true
        case .iCloudDrive, .dropbox, .googleDrive: return false
        }
    }

    /// The line for an iCloud target a build without the entitlement
    /// cannot open, per 9.1. Ticket 017 greys the entry out.
    public static let iCloudUnavailableLine =
        "This library backed up to iCloud on the App Store version of Empo. This copy cannot open "
        + "iCloud. Restore from another target, or install Empo from the App Store."

    /// The hint for one streamed descriptor.
    public static func line(
        for descriptor: TargetDescriptor, canOpenICloud: Bool = true
    ) -> String {
        if descriptor.provider == .iCloudDrive, !canOpenICloud {
            return iCloudUnavailableLine
        }
        let label = descriptor.label
        guard isSelfHosted(descriptor.provider), !descriptor.root.isEmpty else {
            return "This library is also backed up to \(label). Add \(label) to see those backups "
                + "too."
        }
        return "This library is also backed up to \(label). Add it and point it at "
            + "\(descriptor.root) to see those backups too."
    }

    /// The hints for every streamed descriptor this install has not
    /// added yet, in label order.
    public static func lines(
        streamed: [TargetDescriptor],
        configuredTargetIds: Set<String> = [],
        canOpenICloud: Bool = true
    ) -> [String] {
        streamed
            .filter { !configuredTargetIds.contains($0.id) }
            .sorted { $0.label < $1.label }
            .map { line(for: $0, canOpenICloud: canOpenICloud) }
    }
}

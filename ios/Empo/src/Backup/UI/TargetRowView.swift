import GameProbe
import SwiftUI

extension BackupProviderKind {

    var symbolName: String {
        switch self {
        case .iCloudDrive: return "icloud"
        case .dropbox: return "shippingbox"
        case .googleDrive: return "externaldrive"
        case .s3: return "cylinder.split.1x2"
        case .webdav: return "server.rack"
        }
    }

    /// The service's own logo, for the services that have one.
    var markName: String? {
        switch self {
        case .iCloudDrive: return "ICloudMark"
        case .dropbox: return "DropboxMark"
        case .googleDrive: return "GoogleDriveMark"
        case .s3, .webdav: return nil
        }
    }
}

/// One row of the location list, per SPEC 13.5.
///
/// The service symbol, the name, and exactly one state under it. The
/// account hint shows only where it adds a fact the name lacks.
struct TargetRowView: View {

    let row: TargetRow
    let target: TargetDescriptor

    private var hint: String? {
        guard let hint = row.accountHint, hint != row.title else { return nil }
        return hint
    }

    var body: some View {
        HStack(spacing: Spacing.lg) {
            AccountAvatar(photo: target.accountPhoto, provider: target.provider, size: 36)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(row.title)
                if let hint {
                    AccountHintText(hint: hint, provider: target.provider)
                }
                Text(row.stateLine)
                    .font(.footnote)
                    .foregroundStyle(row.state.isProblem ? Color.red : Color.secondary)
                if let line = row.foregroundOnlyLine {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
        .opacity(row.isDisabled ? Alpha.disabled : 1)
    }
}

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
        case .sftp: return "lock.shield"
        }
    }
}

/// One row of the location list, per SPEC 13.5.
///
/// The service symbol, the name, and exactly one state under it. The
/// account hint shows only where it adds a fact the name lacks.
struct TargetRowView: View {

    let row: TargetRow
    let provider: BackupProviderKind

    private var hint: String? {
        guard let hint = row.accountHint, hint != row.title else { return nil }
        return hint
    }

    private var stateColor: Color {
        switch row.state {
        case .current, .paused, .cannotOpen: return .secondary
        case .placeholder, .needsSignIn, .blockedByPermissions, .rejected, .full, .unreachable:
            return .warning
        }
    }

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: provider.symbolName)
                .font(.title3)
                .foregroundStyle(.brand)
                .frame(width: IconSize.row + Spacing.md)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(row.title)
                if let hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(row.stateLine)
                    .font(.footnote)
                    .foregroundStyle(stateColor)
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

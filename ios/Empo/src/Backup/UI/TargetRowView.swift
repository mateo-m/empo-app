import GameProbe
import SwiftUI

/// One row of the target list, per SPEC 13.5.
///
/// First line: the service name and the account hint. Second line:
/// exactly one state. The action button of 13.5 is a sibling of this
/// view and not a child, because a button inside a `NavigationLink`
/// label takes no tap of its own.
struct TargetRowView: View {

    let row: TargetRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(row.title)
                if let hint = row.accountHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(row.stateLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let line = row.foregroundOnlyLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .opacity(row.isDisabled ? 0.5 : 1)
    }
}

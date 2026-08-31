import GameProbe
import SwiftUI

/// The mode picker of SPEC 3.5 and 13.15.
///
/// One picker behind two doors: the first-backup ask presents it,
/// and the mode row of the Backup sheet pushes it. Both show the same
/// two rows and the same words, because `BackupModePicker` holds
/// them.
struct BackupModePickerView: View {

    let fullBytes: Int64
    let slimBytes: Int64
    let chosen: BackupMode?
    let choose: (BackupMode) -> Void

    var body: some View {
        ForEach(BackupModePicker.options(fullBytes: fullBytes, slimBytes: slimBytes), id: \.mode) {
            option in
            Button {
                choose(option.mode)
            } label: {
                HStack(alignment: .top, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(option.label)
                            .foregroundStyle(.primary)
                        Text(option.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(BackupText.bytes(option.sizeBytes))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if option.mode == chosen {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.brand)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

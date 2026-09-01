import GameProbe
import SwiftUI

/// The join ask of SPEC 10.4.
///
/// The join is the consent step, so the sheet says what it copies
/// before the user says yes. One group asks for a confirmation.
/// Several groups need a pick first.
struct SyncJoinSheet: View {

    let ask: SyncJoinAsk
    let join: (DiscoveredSyncGroup) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch ask {
        case .none:
            StandardSheet(title: "No settings to sync", emblem: "arrow.triangle.2.circlepath") {
                SheetBodyText(SyncGroupCopy.noCommonTarget)
                SheetPrimaryButton("OK") { dismiss() }
            }
        case .confirm(let group):
            StandardSheet(
                title: SyncGroupCopy.confirmation(of: group), emblem: "arrow.triangle.2.circlepath"
            ) {
                SheetBodyText(SyncGroupCopy.joinBody)
                VStack(spacing: Spacing.md) {
                    SheetPrimaryButton("Sync settings") {
                        join(group)
                        dismiss()
                    }
                    Button("Not now") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle(size: .md))
                }
            }
        case .pick(let groups):
            picker(groups)
        }
    }

    private func picker(_ groups: [DiscoveredSyncGroup]) -> some View {
        NavigationStack {
            List {
                Section {
                    ForEach(groups) { group in
                        Button {
                            join(group)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(group.deviceNames.joined(separator: ", "))
                                if let at = group.lastChangeAt {
                                    Text("Last change \(BackupText.ago(at))")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(SyncGroupCopy.joinBody)
                }
            }
            .navigationTitle("Sync settings with")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Not now") { dismiss() }
                }
            }
        }
    }
}

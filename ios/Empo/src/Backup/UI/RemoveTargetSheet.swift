import GameProbe
import SwiftUI
import UIKit

/// The remove sheet of SPEC 13.10.
///
/// Removing is local-only. Empo stops backing up there, and the
/// backups already on the service stay in the user's account.
struct RemoveTargetSheet: View {

    let item: BackupTargetItem
    let remove: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var deletesBackups = false
    @State private var refusal: TargetRemovalRefusal?

    private var sheet: TargetRemovalSheet {
        TargetRemovalRules.sheet(
            target: item.descriptor, deleteBackups: deletesBackups,
            deviceName: "this " + UIDevice.current.model)
    }

    var body: some View {
        StandardSheet(
            title: sheet.title,
            trailingButton: SheetBarAction("Cancel") { dismiss() }
        ) {
            SheetBodyText(sheet.body)
            Toggle(sheet.deleteLabel, isOn: $deletesBackups)
                .font(.subheadline)
            if let refusal {
                SheetBodyText(refusal.line)
                    .foregroundStyle(.red)
                VStack(spacing: Spacing.md) {
                    ForEach(refusal.actions, id: \.self) { action in
                        Button(action.label) { press(action) }
                            .buttonStyle(SecondaryButtonStyle(size: .md))
                    }
                }
            } else {
                SheetPrimaryButton(sheet.confirmLabel) { confirm() }
            }
        }
    }

    private func confirm() {
        switch TargetRemovalRules.answer(
            deleteBackups: deletesBackups, state: item.row.state, target: item.descriptor)
        {
        case .remove:
            finish(deletesBackups: false)
        case .removeAndDelete:
            finish(deletesBackups: true)
        case .refuse(let refusal):
            self.refusal = refusal
        }
    }

    private func press(_ action: TargetRemovalRefusalAction) {
        switch action {
        case .removeWithoutDeleting:
            finish(deletesBackups: false)
        case .cancel:
            dismiss()
        }
    }

    private func finish(deletesBackups: Bool) {
        remove(deletesBackups)
        dismiss()
    }
}

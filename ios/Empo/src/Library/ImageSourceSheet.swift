import SwiftUI

/// Modal sheet offering the three image-source options (Photos /
/// Camera / Files) plus an optional "Remove" action when the
/// caller already has an image set. Replaces the previous
/// `confirmationDialog` action-sheet so the UI matches the rest
/// of the app's bottom-sheet patterns (library sort, experimental
/// info). The old system dialog looked out of place next to
/// native-SwiftUI sheets.
struct ImageSourceSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let hasExisting: Bool
    let onPickPhoto: () -> Void
    let onTakePhoto: () -> Void
    let onPickFile: () -> Void
    let onRemove: (() -> Void)?

    /// Hide the "Take Photo" row when the device can't actually
    /// launch the camera (iPad without a rear camera, Simulator).
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        StandardSheet(
            title: title,
            trailingButton: ("Cancel", { isPresented = false })
        ) {
            SheetCard {
                ImageSourceRow(
                    icon: "photo.on.rectangle",
                    label: "Camera Roll"
                ) {
                    isPresented = false
                    onPickPhoto()
                }

                if cameraAvailable {
                    SheetRowSeparator(leadingColumn: 24)
                    ImageSourceRow(
                        icon: "camera",
                        label: "Take Photo"
                    ) {
                        isPresented = false
                        onTakePhoto()
                    }
                }

                SheetRowSeparator(leadingColumn: 24)
                ImageSourceRow(
                    icon: "folder",
                    label: "Choose File"
                ) {
                    isPresented = false
                    onPickFile()
                }
            }

            if hasExisting, let onRemove {
                // Destructive "Remove" action as its own card so
                // it reads as separate from the sources, per the
                // sheet rules.
                SheetCard {
                    ImageSourceRow(
                        icon: "trash",
                        label: "Remove",
                        role: .destructive
                    ) {
                        isPresented = false
                        onRemove()
                    }
                }
            }
        }
    }
}

/// Single tappable row inside `ImageSourceSheet`. Kept private to
/// the file because the layout (SF Symbol + label + chevron) is
/// specific to this sheet. The library sort rows use a different
/// right-edge accessory (a checkmark).
private struct ImageSourceRow: View {
    let icon: String
    let label: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: Spacing.lg) {
                Image(systemName: icon)
                    .foregroundStyle(role == .destructive ? .red : .secondary)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(role == .destructive ? .red : .primary)
                Spacer()
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.lg)
            .contentShape(Rectangle())
        }
    }
}

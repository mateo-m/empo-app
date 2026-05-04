import SwiftUI


/// Modal sheet offering the three image-source options (Photos /
/// Camera / Files) plus an optional "Remove" action when the
/// caller already has an image set. Replaces the previous
/// `confirmationDialog` action-sheet so the UI matches the rest
/// of the app's bottom-sheet patterns (library sort, experimental
/// info) instead of surfacing a system dialog that looks out of
/// place next to native-SwiftUI sheets.
struct ImageSourceSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let hasExisting: Bool
    let onPickPhoto: () -> Void
    let onTakePhoto: () -> Void
    let onPickFile: () -> Void
    let onRemove: (() -> Void)?

    @State private var measuredHeight: CGFloat = 0

    /// Hide the "Take Photo" row when the device can't actually
    /// launch the camera (iPad without a rear camera, Simulator).
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                // Sources group - rounded card that mirrors the
                // native grouped-list look without embedding in a
                // List (which would want to fill the sheet).
                VStack(spacing: 0) {
                    ImageSourceRow(
                        icon: "photo.on.rectangle",
                        label: "Camera Roll"
                    ) {
                        isPresented = false
                        onPickPhoto()
                    }

                    if cameraAvailable {
                        rowSeparator
                        ImageSourceRow(
                            icon: "camera",
                            label: "Take Photo"
                        ) {
                            isPresented = false
                            onTakePhoto()
                        }
                    }

                    rowSeparator
                    ImageSourceRow(
                        icon: "folder",
                        label: "Choose File"
                    ) {
                        isPresented = false
                        onPickFile()
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: Radius.md))

                if hasExisting, let onRemove {
                    // Destructive "Remove" action as its own card
                    // so it reads as separate from the sources,
                    // matching the sectioning pattern users expect
                    // from grouped lists.
                    ImageSourceRow(
                        icon: "trash",
                        label: "Remove",
                        role: .destructive
                    ) {
                        isPresented = false
                        onRemove()
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: Radius.md))
                }
            }
            .padding(Spacing.xl)
            .intrinsicSheetContent(measuredHeight: $measuredHeight)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .intrinsicSheetDetent(measuredHeight: measuredHeight)
        .tint(.brand)
    }

    /// Hairline separator between rows inside the sources card.
    /// Indented past the icon column so it only spans the text
    /// area, matching the visual rhythm of UIKit grouped lists.
    private var rowSeparator: some View {
        Divider()
            .padding(.leading, Spacing.lg + 24 + Spacing.lg)
    }
}


/// Single tappable row inside `ImageSourceSheet`. Kept private to
/// the file because the layout (SF Symbol + label + chevron) is
/// specific to this sheet - the library sort rows use a different
/// right-edge accessory (a checkmark).
private struct ImageSourceRow: View {
    let icon: String
    let label: String
    var role: ButtonRole? = nil
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

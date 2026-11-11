// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct ImageSourceSheet: View {
    @Binding var isPresented: Bool
    let title: LocalizedStringResource
    let hasExisting: Bool
    let onPickPhoto: () -> Void
    let onTakePhoto: () -> Void
    let onPickFile: () -> Void
    let onRemove: (() -> Void)?

    /// Hide the "Take photo" row when the device cannot
    /// launch the camera (iPad without a rear camera, Simulator).
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        StandardSheet(
            title: title,
            barAction: SheetBarAction("Cancel") { isPresented = false }
        ) {
            SheetCard {
                SheetRow(
                    icon: "photo.on.rectangle",
                    label: LocalizedStringResource("Photos", comment: "Pick an image from the Photos app"),
                    iconColor: .secondary
                ) {
                    isPresented = false
                    onPickPhoto()
                }

                if cameraAvailable {
                    SheetRowSeparator(leadingColumn: 24)
                    SheetRow(icon: "camera", label: "Take photo", iconColor: .secondary) {
                        isPresented = false
                        onTakePhoto()
                    }
                }

                SheetRowSeparator(leadingColumn: 24)
                SheetRow(icon: "folder", label: "Choose file", iconColor: .secondary) {
                    isPresented = false
                    onPickFile()
                }
            }

            if hasExisting, let onRemove {
                SheetCard {
                    SheetRow(icon: "trash", label: "Delete image", role: .destructive) {
                        isPresented = false
                        onRemove()
                    }
                }
            }
        }
    }
}

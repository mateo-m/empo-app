import SwiftUI

// ============================================================================
// MARK: - Controls Edit Dialogs
// ============================================================================

/// A ViewModifier that attaches all controls-editing dialogs (add, reset,
/// edit button, label editor, key picker, size picker). PlayerView owns the
/// trigger bindings; this modifier owns the secondary dialog state.
struct ControlsEditDialogs: ViewModifier {
    var layout: ControlsLayout

    // Trigger bindings — owned by PlayerView, toggled by toolbar/gestures
    @Binding var showAddSheet: Bool
    @Binding var showResetConfirm: Bool
    @Binding var editingButton: ButtonModel?
    @Binding var showEditMenu: Bool

    // Secondary dialog state — owned here, triggered from edit menu
    @State private var showLabelEditor = false
    @State private var showKeyPicker = false
    @State private var showSizePicker = false
    @State private var editLabelText = ""

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Add Button", isPresented: $showAddSheet) {
                ForEach(keyCatalog) { entry in
                    Button(entry.label) {
                        layout.addButton(label: entry.label, scancode: entry.scancode)
                    }
                }
            }
            .alert("Reset Controls", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    withAnimation(Motion.standard) {
                        layout.resetToDefaults()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Restore default layout?")
            }
            .confirmationDialog("Edit Button", isPresented: $showEditMenu) {
                if let btn = editingButton {
                    Button("Change Label") {
                        editLabelText = btn.label
                        showLabelEditor = true
                    }
                    Button("Change Key (now: \(scancodeDisplayName(btn.scancode)))") {
                        showKeyPicker = true
                    }
                    Button("Change Size (now: \(Int(btn.size)))") {
                        showSizePicker = true
                    }
                    Button("Delete", role: .destructive) {
                        withAnimation(Motion.snappy) {
                            layout.removeButton(id: btn.id)
                        }
                    }
                }
            }
            .alert("Button Label", isPresented: $showLabelEditor) {
                TextField("Label", text: $editLabelText)
                Button("OK") {
                    if let btn = editingButton, !editLabelText.isEmpty {
                        layout.updateButton(id: btn.id, label: editLabelText)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter the text to display on this button")
            }
            .confirmationDialog("Emulated Key", isPresented: $showKeyPicker) {
                if let btn = editingButton {
                    ForEach(keyCatalog) { entry in
                        let prefix = entry.scancode == btn.scancode ? "\u{2713} " : ""
                        Button("\(prefix)\(entry.label)") {
                            layout.updateButton(id: btn.id, scancode: entry.scancode)
                        }
                    }
                }
            }
            .confirmationDialog("Button Size", isPresented: $showSizePicker) {
                if let btn = editingButton {
                    let sizes: [(String, CGFloat)] = [
                        ("Small (38)", 38), ("Medium (50)", 50),
                        ("Default (56)", 56), ("Large (68)", 68), ("XL (80)", 80),
                    ]
                    ForEach(sizes, id: \.1) { name, size in
                        let prefix = Int(size) == Int(btn.size) ? "\u{2713} " : ""
                        Button("\(prefix)\(name)") {
                            layout.updateButton(id: btn.id, size: size)
                        }
                    }
                }
            }
    }
}

extension View {
    func controlsEditDialogs(
        layout: ControlsLayout,
        showAddSheet: Binding<Bool>,
        showResetConfirm: Binding<Bool>,
        editingButton: Binding<ButtonModel?>,
        showEditMenu: Binding<Bool>
    ) -> some View {
        modifier(ControlsEditDialogs(
            layout: layout,
            showAddSheet: showAddSheet,
            showResetConfirm: showResetConfirm,
            editingButton: editingButton,
            showEditMenu: showEditMenu
        ))
    }
}

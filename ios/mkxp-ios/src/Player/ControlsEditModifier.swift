import SwiftUI


struct ButtonEditSheet: View {
    var layout: ControlsLayout
    let buttonID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var labelText = ""

    private let sizes: [(String, CGFloat)] = [
        ("Small", 44), ("Medium", 50),
        ("Default", 56), ("Large", 68), ("Extra large", 80),
    ]

    private var button: ButtonModel? {
        layout.buttons.first { $0.id == buttonID }
    }

    var body: some View {
        NavigationStack {
            if let button {
                List {
                    Section {
                        HStack {
                            Text("Label")
                            Spacer()
                            TextField("Label", text: $labelText)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: labelText) { _, newValue in
                                    if !newValue.isEmpty {
                                        layout.updateButton(id: buttonID, label: newValue)
                                    }
                                }
                        }

                        NavigationLink {
                            keyPickerList(current: button.scancode)
                        } label: {
                            LabeledContent("Key", value: scancodeDisplayName(button.scancode))
                        }
                    }

                    Section("Size") {
                        ForEach(sizes, id: \.1) { name, size in
                            HStack {
                                Text(name)
                                Spacer()
                                Text("\(Int(size))pt")
                                    .foregroundStyle(.secondary)
                                if Int(size) == Int(button.size) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.brand)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                layout.updateButton(id: buttonID, size: size)
                            }
                        }
                    }

                Section {
                    Button {
                        dismiss()
                        withAnimation(Motion.snappy) {
                            layout.removeButton(id: buttonID)
                        }
                    } label: {
                        Text("Delete button")
                    }
                    .buttonStyle(.secondary(tint: .destructive))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg))
                }
                }
                .navigationTitle("Edit button")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            AppWindow.setAllowKeyWindow(true)
            labelText = button?.label ?? ""
        }
        .onDisappear {
            AppWindow.setAllowKeyWindow(false)
        }
    }

    private func keyPickerList(current scancode: Int32) -> some View {
        List {
            ForEach(keyCatalog) { entry in
                HStack {
                    Text(entry.label)
                    Spacer()
                    if entry.scancode == scancode {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.brand)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    layout.updateButton(id: buttonID, scancode: entry.scancode)
                }
            }
        }
        .navigationTitle("Emulated key")
        .navigationBarTitleDisplayMode(.inline)
    }
}


struct ControlsEditDialogs: ViewModifier {
    var layout: ControlsLayout

    @Binding var showAddSheet: Bool
    @Binding var showResetConfirm: Bool
    @Binding var editingButton: ButtonModel?

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
                    layout.resetWithStagger()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Restore default layout?")
            }
            .sheet(item: $editingButton) { button in
                ButtonEditSheet(layout: layout, buttonID: button.id)
            }
    }
}

extension View {
    func controlsEditDialogs(
        layout: ControlsLayout,
        showAddSheet: Binding<Bool>,
        showResetConfirm: Binding<Bool>,
        editingButton: Binding<ButtonModel?>
    ) -> some View {
        modifier(ControlsEditDialogs(
            layout: layout,
            showAddSheet: showAddSheet,
            showResetConfirm: showResetConfirm,
            editingButton: editingButton
        ))
    }
}

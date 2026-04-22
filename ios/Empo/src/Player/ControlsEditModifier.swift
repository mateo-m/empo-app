import SwiftUI


struct AddButtonSheet: View {
    var layout: ControlsLayout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Common") {
                    ForEach(keyCatalog.filter { isCommon($0) }) { entry in
                        row(for: entry)
                    }
                }
                Section("Letters") {
                    ForEach(keyCatalog.filter { isLetter($0) }) { entry in
                        row(for: entry)
                    }
                }
                Section("Numbers") {
                    ForEach(keyCatalog.filter { isNumber($0) }) { entry in
                        row(for: entry)
                    }
                }
                Section("Function keys") {
                    ForEach(keyCatalog.filter { isFunction($0) }) { entry in
                        row(for: entry)
                    }
                }
            }
            .navigationTitle("Add button")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(for entry: KeyEntry) -> some View {
        HStack {
            Text(entry.label)
            Spacer()
            Text(scancodeDisplayName(entry.scancode))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            dismiss()
            layout.addButton(label: entry.label, scancode: entry.scancode)
        }
    }

    private func isCommon(_ entry: KeyEntry) -> Bool {
        let common: Set<Int32> = [
            Int32(MKXP_SCANCODE_Z), Int32(MKXP_SCANCODE_X),
            Int32(MKXP_SCANCODE_LSHIFT), Int32(MKXP_SCANCODE_LCTRL),
            Int32(MKXP_SCANCODE_SPACE), Int32(MKXP_SCANCODE_RETURN),
            Int32(MKXP_SCANCODE_ESCAPE), Int32(MKXP_SCANCODE_TAB),
            Int32(MKXP_SCANCODE_LALT), Int32(MKXP_SCANCODE_BACKSPACE),
        ]
        return common.contains(entry.scancode)
    }

    private func isLetter(_ entry: KeyEntry) -> Bool {
        entry.scancode >= Int32(MKXP_SCANCODE_A) && entry.scancode <= Int32(MKXP_SCANCODE_Z)
            && !isCommon(entry)
    }

    private func isNumber(_ entry: KeyEntry) -> Bool {
        entry.scancode >= Int32(MKXP_SCANCODE_1) && entry.scancode <= Int32(MKXP_SCANCODE_0)
    }

    private func isFunction(_ entry: KeyEntry) -> Bool {
        entry.scancode >= Int32(MKXP_SCANCODE_F1) && entry.scancode <= Int32(MKXP_SCANCODE_F12)
    }
}


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

                    Section("Opacity") {
                        // Integer-percent label mirrors the Photos
                        // adjust-panel idiom so the slider's exact
                        // value stays visible while dragging.
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { button.opacity },
                                    set: { layout.updateButton(id: buttonID, opacity: $0) }
                                ),
                                in: 0.2...1.0
                            )
                            Text("\(Int(button.opacity * 100))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
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


/// Edit sheet specific to the D-pad. The D-pad isn't configurable
/// the same way action buttons are (no label, no key assignment, no
/// delete) so it gets its own slimmed-down sheet with just size and
/// opacity controls.
struct DPadEditSheet: View {
    var layout: ControlsLayout
    @Environment(\.dismiss) private var dismiss

    /// Size presets match the action button sheet's progression so
    /// the two controls feel consistent when sized alongside each
    /// other. The D-pad's default (140pt) is the middle preset.
    private let sizes: [(String, CGFloat)] = [
        ("Small", 110), ("Medium", 125),
        ("Default", 140), ("Large", 160), ("Extra large", 180),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Size") {
                    ForEach(sizes, id: \.1) { name, size in
                        HStack {
                            Text(name)
                            Spacer()
                            Text("\(Int(size))pt")
                                .foregroundStyle(.secondary)
                            if Int(size) == Int(layout.dpadSize) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.brand)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            layout.dpadSize = size
                        }
                    }
                }

                Section("Opacity") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { layout.dpadOpacity },
                                set: { layout.dpadOpacity = $0 }
                            ),
                            in: 0.2...1.0
                        )
                        Text("\(Int(layout.dpadOpacity * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            .navigationTitle("Edit D-pad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}


struct ControlsEditDialogs: ViewModifier {
    var layout: ControlsLayout

    @Binding var showAddSheet: Bool
    @Binding var showResetConfirm: Bool
    @Binding var editingButton: ButtonModel?
    @Binding var editingDPad: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showAddSheet) {
                AddButtonSheet(layout: layout)
            }
            .alert("Reset Controls", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    layout.resetWithStagger()
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Restore default layout?")
            }
            .sheet(item: $editingButton) { button in
                ButtonEditSheet(layout: layout, buttonID: button.id)
            }
            .sheet(isPresented: $editingDPad) {
                DPadEditSheet(layout: layout)
            }
    }
}

extension View {
    func controlsEditDialogs(
        layout: ControlsLayout,
        showAddSheet: Binding<Bool>,
        showResetConfirm: Binding<Bool>,
        editingButton: Binding<ButtonModel?>,
        editingDPad: Binding<Bool>
    ) -> some View {
        modifier(ControlsEditDialogs(
            layout: layout,
            showAddSheet: showAddSheet,
            showResetConfirm: showResetConfirm,
            editingButton: editingButton,
            editingDPad: editingDPad
        ))
    }
}

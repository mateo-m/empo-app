import GameProbe
import SwiftUI

struct AddButtonSheet: View {
    var layout: ControlsLayout
    @Environment(\.dismiss) private var dismiss

    /// The file format caps key buttons + action buttons at 21 per
    /// orientation. A layout saved over the cap would fail validation
    /// on its next load and silently reset, so the add rows disable
    /// at the limit instead.
    private var atCap: Bool {
        layout.combinedButtonCount >= ControlsLayout.maxButtonsPerOrientation
    }

    var body: some View {
        NavigationStack {
            List {
                if atCap {
                    Section {
                        Text(
                            "This layout has the maximum of \(ControlsLayout.maxButtonsPerOrientation) buttons. Delete one to add another."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                Section("Empo actions") {
                    ForEach(EmpoActionCatalog.all.filter(\.touchValid), id: \.id) { action in
                        actionRow(for: action)
                    }
                }
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
        .opacity(atCap ? 0.4 : 1)
        .onTapGesture {
            guard !atCap else { return }
            dismiss()
            layout.addButton(label: entry.label, scancode: entry.scancode)
        }
    }

    private func actionRow(for action: EmpoAction) -> some View {
        HStack {
            Image(systemName: action.symbolName)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
                Text(action.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .opacity(atCap ? 0.4 : 1)
        .onTapGesture {
            guard !atCap else { return }
            dismiss()
            layout.addActionButton(action: action.id)
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
    @State private var labelEditSnapshotRecorded = false

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
                                    if !labelEditSnapshotRecorded && newValue != button.label {
                                        layout.recordEditSnapshot()
                                        labelEditSnapshotRecorded = true
                                    }
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
                                layout.recordEditSnapshot()
                                layout.updateButton(id: buttonID, size: size)
                            }
                        }
                    }

                    Section("Opacity") {
                        // The integer-percent label mirrors the Photos
                        // adjust-panel idiom, so the exact slider
                        // value stays visible while you drag.
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { button.opacity },
                                    set: { layout.updateButton(id: buttonID, opacity: $0) }
                                ),
                                in: 0.2...1.0
                            ) { editing in
                                if editing {
                                    layout.recordEditSnapshot()
                                }
                            }
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
                        .listRowInsets(
                            EdgeInsets(
                                top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg
                            ))
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
                    layout.recordEditSnapshot()
                    layout.updateButton(id: buttonID, scancode: entry.scancode)
                }
            }
        }
        .navigationTitle("Emulated key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Edit sheet for a function button. The action is fixed at add time
/// (a read-only row shows its name and description); only size,
/// opacity, and delete apply.
struct ActionButtonEditSheet: View {
    var layout: ControlsLayout
    let buttonID: UUID
    @Environment(\.dismiss) private var dismiss

    private let sizes: [(String, CGFloat)] = [
        ("Small", 44), ("Medium", 50),
        ("Default", 56), ("Large", 68), ("Extra large", 80),
    ]

    private var button: ActionButtonModel? {
        layout.actionButtons.first { $0.id == buttonID }
    }

    private var action: EmpoAction? {
        button.flatMap { EmpoActionCatalog.action(id: $0.action) }
    }

    var body: some View {
        NavigationStack {
            if let button {
                List {
                    Section {
                        HStack {
                            Image(systemName: action?.symbolName ?? "questionmark")
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action?.displayName ?? button.action)
                                if let blurb = action?.blurb {
                                    Text(blurb)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                                layout.recordEditSnapshot()
                                layout.updateActionButton(id: buttonID, size: size)
                            }
                        }
                    }

                    Section("Opacity") {
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { button.opacity },
                                    set: { layout.updateActionButton(id: buttonID, opacity: $0) }
                                ),
                                in: 0.2...1.0
                            ) { editing in
                                if editing {
                                    layout.recordEditSnapshot()
                                }
                            }
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
                                layout.removeActionButton(id: buttonID)
                            }
                        } label: {
                            Text("Delete button")
                        }
                        .buttonStyle(.secondary(tint: .destructive))
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(
                            EdgeInsets(
                                top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg
                            ))
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
    }
}

/// Edit sheet specific to the movement control. Unlike an action
/// button, it has no label, no key assignment, and no delete option.
/// So it gets its own smaller sheet with style, size, and opacity
/// controls.
struct DPadEditSheet: View {
    var layout: ControlsLayout
    @Environment(\.dismiss) private var dismiss

    /// Size presets match the action button sheet's progression so
    /// the two controls feel consistent when you size them side by
    /// side. The D-pad's default (140pt) is the middle preset.
    private let sizes: [(String, CGFloat)] = [
        ("Small", 110), ("Medium", 125),
        ("Default", 140), ("Large", 160), ("Extra large", 180),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Style") {
                    // Applies to the ACTIVE orientation only, same
                    // scope as size and opacity (and the same
                    // single-orientation undo snapshot).
                    Picker("Style", selection: styleBinding) {
                        Text("D-pad").tag(MovementStyle.dpad)
                        Text("Joystick").tag(MovementStyle.stick)
                    }
                    .pickerStyle(.segmented)
                }

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
                            layout.recordEditSnapshot()
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
                        ) { editing in
                            if editing {
                                layout.recordEditSnapshot()
                            }
                        }
                        Text("\(Int(layout.dpadOpacity * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            .navigationTitle(layout.dpadStyle == .stick ? "Edit joystick" : "Edit D-pad")
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

    private var styleBinding: Binding<MovementStyle> {
        Binding(
            get: { layout.dpadStyle },
            set: { newStyle in
                guard newStyle != layout.dpadStyle else { return }
                layout.recordEditSnapshot()
                layout.dpadStyle = newStyle
            }
        )
    }
}

struct ControlsEditDialogs: ViewModifier {
    var layout: ControlsLayout

    @Binding var showAddSheet: Bool
    @Binding var showResetConfirm: Bool
    @Binding var editingButton: ButtonModel?
    @Binding var editingActionButton: ActionButtonModel?
    @Binding var editingDPad: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showAddSheet) {
                AddButtonSheet(layout: layout)
            }
            .alert(layout.resetConfirmationTitle, isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    layout.resetToResolvedDefault()
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(layout.resetConfirmationMessage())
            }
            .sheet(item: $editingButton) { button in
                ButtonEditSheet(layout: layout, buttonID: button.id)
            }
            .sheet(item: $editingActionButton) { button in
                ActionButtonEditSheet(layout: layout, buttonID: button.id)
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
        editingActionButton: Binding<ActionButtonModel?>,
        editingDPad: Binding<Bool>
    ) -> some View {
        modifier(
            ControlsEditDialogs(
                layout: layout,
                showAddSheet: showAddSheet,
                showResetConfirm: showResetConfirm,
                editingButton: editingButton,
                editingActionButton: editingActionButton,
                editingDPad: editingDPad
            ))
    }
}

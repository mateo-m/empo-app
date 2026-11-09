// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

struct AddButtonSheet: View {
    var layout: ControlsLayout
    var actions: PlayerActionRegistry?
    @Environment(\.dismiss) private var dismiss

    private var atCap: Bool {
        layout.combinedButtonCount >= ControlLimits.maxButtonsPerOrientation
    }

    var body: some View {
        NavigationStack {
            List {
                if atCap {
                    Section {
                        Text(
                            "This layout has the maximum of \(ControlLimits.maxButtonsPerOrientation) buttons. Delete one to add another."
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
                KeyCodeSections { code, hint in
                    KeyCodeLabel(code: code, hint: hint)
                        .contentShape(Rectangle())
                        .opacity(atCap ? 0.4 : 1)
                        .onTapGesture {
                            guard !atCap, let scancode = KeyCodeTable.scancode(for: code) else { return }
                            dismiss()
                            layout.addButton(
                                label: KeyCodeTable.displayName(for: code) ?? code, scancode: scancode)
                        }
                }
            }
            .navigationTitle("Add button")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetBarButton.cancel { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func actionRow(for action: EmpoAction) -> some View {
        HStack {
            Image(systemName: action.symbolName)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.localizedName)
                Text(action.localizedBlurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let actions, !actions.isAvailable(action.id) {
                    Text(BindingsCatalog.unavailableActionNote(action.id, in: .addButtonSheet))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
}

/// The key list of the add-button sheet and the key picker. Each key
/// of the common group shows what it does in most RPG Maker games.
private struct KeyCodeSections<Row: View>: View {
    @ViewBuilder let row: (_ code: String, _ hint: String?) -> Row

    var body: some View {
        let buckets = KeyCodeTable.codesByPickerGroup
        ForEach(KeyCodePickerGroup.allCases, id: \.self) { group in
            if let codes = buckets[group], !codes.isEmpty {
                Section(group.localizedTitle) {
                    ForEach(codes, id: \.self) { code in
                        row(code, group == .common ? BindingsCatalog.commonKeyAnnotations[code] : nil)
                    }
                }
            }
        }
    }
}

private struct KeyCodeLabel: View {
    let code: String
    let hint: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(KeyCodeTable.displayName(for: code) ?? code)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

enum ControlSizePresets {
    static let button: [(LocalizedStringResource, CGFloat)] = [
        ("Small", 44), ("Medium", 50),
        ("Standard", CGFloat(ControlLimits.defaultButtonSize)), ("Large", 68), ("Extra large", 80),
    ]
    static let dpad: [(LocalizedStringResource, CGFloat)] = [
        ("Small", 110), ("Medium", 125),
        ("Standard", CGFloat(ControlLimits.defaultDPadSize)), ("Large", 160), ("Extra large", 180),
    ]
}

struct ControlSizeSection: View {
    let sizes: [(LocalizedStringResource, CGFloat)]
    let current: CGFloat
    let onSelect: (CGFloat) -> Void

    var body: some View {
        Section("Size") {
            ForEach(sizes, id: \.1) { name, size in
                HStack {
                    Text(name)
                    Spacer()
                    Text("\(Int(size))pt", comment: "Size of an on-screen control, in points.")
                        .foregroundStyle(.secondary)
                    if Int(size) == Int(current) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.brand)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect(size) }
            }
        }
    }
}

struct ControlOpacitySection: View {
    let opacity: Double
    let onEditingBegan: () -> Void
    let onChange: (Double) -> Void

    var body: some View {
        Section("Opacity") {
            HStack {
                Slider(
                    value: Binding(get: { opacity }, set: onChange),
                    in: 0.2...1.0
                ) { editing in
                    if editing {
                        onEditingBegan()
                    }
                }
                Text(opacity.formatted(.percent.precision(.fractionLength(0))))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}

struct ControlDeleteSection: View {
    let onDelete: () -> Void

    var body: some View {
        Section {
            Button {
                onDelete()
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
}

struct ButtonEditSheet: View {
    var layout: ControlsLayout
    let buttonID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var labelText = ""
    @State private var labelEditSnapshotRecorded = false

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
                            TextField("e.g. Z", text: $labelText)
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
                            LabeledContent("Key", value: keyName(button.scancode))
                        }
                    }

                    ControlSizeSection(
                        sizes: ControlSizePresets.button, current: button.size
                    ) { size in
                        layout.recordEditSnapshot()
                        layout.updateButton(id: buttonID, size: size)
                    }

                    ControlOpacitySection(
                        opacity: button.opacity,
                        onEditingBegan: { layout.recordEditSnapshot() },
                        onChange: { layout.updateButton(id: buttonID, opacity: $0) }
                    )

                    ControlDeleteSection {
                        dismiss()
                        withAnimation(Motion.snappy) {
                            layout.removeButton(id: buttonID)
                        }
                    }
                }
                .navigationTitle("Edit button")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        SheetBarButton.done { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            AppWindow.claimKey(.buttonEditor)
            labelText = button?.label ?? ""
        }
        .onDisappear {
            AppWindow.releaseKey(.buttonEditor)
        }
    }

    private func keyName(_ scancode: Int32) -> String {
        KeyCodeTable.code(for: scancode).flatMap { KeyCodeTable.displayName(for: $0) }
            ?? String(
                localized: "Unknown key",
                comment: "Shown as the key of an on-screen button when Empo does not know its key.")
    }

    private func keyPickerList(current scancode: Int32) -> some View {
        List {
            KeyCodeSections { code, hint in
                let keyScancode = KeyCodeTable.scancode(for: code)
                KeyCodeLabel(code: code, hint: hint)
                    .overlay(alignment: .trailing) {
                        if keyScancode == scancode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.brand)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard let keyScancode else { return }
                        layout.recordEditSnapshot()
                        layout.updateButton(id: buttonID, scancode: keyScancode)
                    }
            }
        }
        .navigationTitle("Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ActionButtonEditSheet: View {
    var layout: ControlsLayout
    let buttonID: UUID
    @Environment(\.dismiss) private var dismiss

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
                                Text(action?.localizedName ?? button.action)
                                if let blurb = action?.localizedBlurb {
                                    Text(blurb)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    ControlSizeSection(
                        sizes: ControlSizePresets.button, current: button.size
                    ) { size in
                        layout.recordEditSnapshot()
                        layout.updateActionButton(id: buttonID, size: size)
                    }

                    ControlOpacitySection(
                        opacity: button.opacity,
                        onEditingBegan: { layout.recordEditSnapshot() },
                        onChange: { layout.updateActionButton(id: buttonID, opacity: $0) }
                    )

                    ControlDeleteSection {
                        dismiss()
                        withAnimation(Motion.snappy) {
                            layout.removeActionButton(id: buttonID)
                        }
                    }
                }
                .navigationTitle("Edit button")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        SheetBarButton.done { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

struct DPadEditSheet: View {
    var layout: ControlsLayout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Style") {
                    Picker("Style", selection: styleBinding) {
                        Text("D-pad").tag(MovementStyle.dpad)
                        Text("Joystick").tag(MovementStyle.stick)
                    }
                    .pickerStyle(.segmented)
                }

                ControlSizeSection(
                    sizes: ControlSizePresets.dpad, current: layout.dpadSize
                ) { size in
                    layout.recordEditSnapshot()
                    layout.dpadSize = size
                }

                ControlOpacitySection(
                    opacity: layout.dpadOpacity,
                    onEditingBegan: { layout.recordEditSnapshot() },
                    onChange: { layout.dpadOpacity = $0 }
                )
            }
            .navigationTitle(layout.dpadStyle == .stick ? "Edit joystick" : "Edit D-pad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetBarButton.done { dismiss() }
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

/// SwiftUI shows one sheet or alert at a time, and two fingers can tap
/// two controls in one frame.
enum ControlsEditDialog: Hashable, Identifiable {
    case addButton, resetConfirm, dpad
    case button(UUID)
    case actionButton(UUID)

    var id: Self { self }
}

struct ControlsEditDialogs: ViewModifier {
    var layout: ControlsLayout
    var actions: PlayerActionRegistry?

    @Binding var dialog: ControlsEditDialog?

    func body(content: Content) -> some View {
        content
            .sheet(
                item: Binding(
                    get: { dialog == .resetConfirm ? nil : dialog },
                    set: { dialog = $0 })
            ) { dialog in
                switch dialog {
                case .addButton: AddButtonSheet(layout: layout, actions: actions)
                case .dpad: DPadEditSheet(layout: layout)
                case .button(let id): ButtonEditSheet(layout: layout, buttonID: id)
                case .actionButton(let id): ActionButtonEditSheet(layout: layout, buttonID: id)
                case .resetConfirm: EmptyView()
                }
            }
            .alert(
                resetTitle,
                isPresented: Binding(
                    get: { dialog == .resetConfirm },
                    set: { if !$0, dialog == .resetConfirm { dialog = nil } })
            ) {
                Button(resetActionTitle, role: .destructive) {
                    layout.resetToResolvedDefault()
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(resetMessage())
            }
    }

    private var resetTitle: LocalizedStringResource {
        if case .pinnedProfile(let name) = layout.provenance {
            return "Stop using \(name)?"
        }
        return layout.hasManifestTouchSection ? "Reset to game default?" : "Reset to Empo default?"
    }

    private var resetActionTitle: LocalizedStringResource {
        if case .pinnedProfile = layout.provenance {
            return "Stop using"
        }
        return "Reset"
    }

    private func resetMessage() -> LocalizedStringResource {
        let screenChanges = layout.screenChangesOnReset()
        if case .pinnedProfile(let name) = layout.provenance {
            return screenChanges
                ? "This game stops using the profile \(name). The profile keeps its layout. The screen returns to automatic placement."
                : "This game stops using the profile \(name). The profile keeps its layout."
        }
        return screenChanges
            ? "This deletes your custom layout and returns the screen to automatic placement. You can't undo this."
            : "This deletes your custom layout. You can't undo this."
    }
}

extension View {
    func controlsEditDialogs(
        layout: ControlsLayout,
        actions: PlayerActionRegistry?,
        dialog: Binding<ControlsEditDialog?>
    ) -> some View {
        modifier(
            ControlsEditDialogs(
                layout: layout,
                actions: actions,
                dialog: dialog
            ))
    }
}

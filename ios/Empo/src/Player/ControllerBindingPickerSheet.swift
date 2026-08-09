import GameProbe
import SwiftUI

/// Key/action picker for remap rows (ticket 005 §4).
struct ControllerBindingPickerSheet: View {
    let elementLabel: String
    let current: BindingMap.Target?
    /// Key sources can stand in for a controller button, which hands
    /// them every binding that button already has. Element sources
    /// cannot: a chain of elements could loop.
    var allowsElements: Bool = false
    let onSelect: (BindingMap.Target) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Actions") {
                    ForEach(EmpoActionCatalog.all, id: \.id) { action in
                        actionRow(
                            label: action.displayName,
                            blurb: action.blurb,
                            target: .action(action.id)
                        )
                    }
                    actionRow(label: "Unbound", target: .unbound)
                }

                if allowsElements {
                    Section("Controller buttons") {
                        ForEach(
                            ControllerRemapCatalog.sections(includingOptional: []), id: \.id
                        ) { section in
                            ForEach(section.elements) { element in
                                actionRow(
                                    label: element.label,
                                    blurb: "Acts as this button",
                                    target: .element(element.id)
                                )
                            }
                        }
                    }
                }

                ForEach(KeyCodePickerGroup.allCases, id: \.self) { group in
                    let codes = KeyCodeTable.codesByPickerGroup[group] ?? []
                    if !codes.isEmpty {
                        Section(KeyCodeTable.pickerGroupTitle(group)) {
                            ForEach(codes, id: \.self) { code in
                                keyRow(code: code, group: group)
                            }
                        }
                    }
                }
            }
            .navigationTitle(elementLabel)
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

    private func actionRow(
        label: String,
        blurb: String? = nil,
        target: BindingMap.Target
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let blurb {
                    Text(blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if targetsMatch(current, target) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.brand)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(target)
            dismiss()
        }
    }

    private func keyRow(code: String, group: KeyCodePickerGroup) -> some View {
        let target: BindingMap.Target = .key(code)
        let title = KeyCodeTable.displayName(for: code) ?? code
        let annotation = group == .common ? ControllerRemapCatalog.commonKeyAnnotations[code] : nil

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let annotation {
                    Text(annotation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if targetsMatch(current, target) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.brand)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(target)
            dismiss()
        }
    }

    private func targetsMatch(_ lhs: BindingMap.Target?, _ rhs: BindingMap.Target) -> Bool {
        switch (lhs, rhs) {
        case (.key(let a), .key(let b)): return a == b
        case (.element(let a), .element(let b)): return a == b
        case (.action(let a), .action(let b)): return a == b
        case (.unbound, .unbound): return true
        default: return false
        }
    }
}

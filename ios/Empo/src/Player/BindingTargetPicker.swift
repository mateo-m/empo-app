import GameProbe
import SwiftUI

/// Key, button and action picker for one binding row (ticket 005 §4).
struct BindingTargetPicker: View {
    let source: BindingSource
    let current: BindingMap.Target?
    let onSelect: (BindingMap.Target) -> Void

    /// A key can stand in for a controller button, which hands it
    /// every binding that button already has. An element cannot: a
    /// chain of elements could loop.
    private var offersElements: Bool { !source.isElement }

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

                if offersElements {
                    Section("Controller buttons") {
                        ForEach(
                            BindingsCatalog.sections(includingOptional: []), id: \.id
                        ) { section in
                            ForEach(section.elements) { row in
                                actionRow(
                                    label: row.label,
                                    blurb: "Acts as this button",
                                    target: .element(row.source.name)
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
            .navigationTitle(BindingsCatalog.label(for: source))
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
        let annotation = group == .common ? BindingsCatalog.commonKeyAnnotations[code] : nil

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
